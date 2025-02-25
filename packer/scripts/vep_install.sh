#!/bin/bash
#
# VEP
#
# Requirements:
#   RODA_BUCKET and VEP_VERSION env vars must be passed in via packer
#

set -xe

export PERL5LIB="/opt/vep"
GSUTIL_PROFILE="/etc/profile.d/gsutil.sh"
GSUTIL_SOURCE="https://storage.googleapis.com/pub/gsutil.tar.gz"
GSUTIL_TARGET_DIR="/opt"
REPOSITORY_URL="https://github.com/Ensembl/ensembl-vep.git"
export VEP_CACHE_DIR="/opt/vep/cache"
export VEP_S3_SOURCE="s3://$RODA_BUCKET"
export VEP_S3_CACHE_PATH="/vep/cache"
export VEP_S3_LOFTEE_PATH="/loftee_data"
export VEP_DIR="/opt/vep"
export PATH="$PATH:/usr/local/bin"
export LC_ALL=en_US.UTF-8

function install_prereqs {
    yum -y install \
        gcc72-c++ \
        gd-devel \
        expat-devel \
        git \
        mysql55-devel \
        perl-App-cpanminus \
        perl-Env \
        unzip \
        which \
        zlib-devel \
        mariadb-devel

    cpanm \
        autodie \
        Compress::Zlib \
        DBD::mysql \
        DBI \
        Digest::MD5 \
        GD \
        HTTP::Tiny \
        JSON \
        Module::Build \
        Try::Tiny

    # Installed alone due to package dependency issues
    cpanm \
        Bio::DB::HTS::Faidx
}

# gsutil used to pull VEP 85 cache from the Broad
function gsutil_install {
    curl "$GSUTIL_SOURCE" | tar --directory "$GSUTIL_TARGET_DIR" -zx
    echo "export PATH=\$PATH:$GSUTIL_TARGET_DIR/gsutil/" >> "$GSUTIL_PROFILE"
}

function download_homo_sapiens_file {
    wget ftp://ftp.ensembl.org/pub/release-${1}/variation/vep/homo_sapiens_vep_${1}_${2}.tar.gz -P /tmp
    # aws s3 cp /tmp/homo_sapiens_vep_${1}_${2}.tar.gz ${VEP_S3_SOURCE}${VEP_S3_CACHE_PATH}/
}

function vep_install {
    mkdir -p "$VEP_CACHE_DIR"
    aws s3 sync --exclude "*" --include "*vep_${VEP_VERSION}*" "$VEP_S3_SOURCE$VEP_S3_CACHE_PATH" /tmp

    # Install VEP - the earliest version available from GitHub is 87
    if [ "$VEP_VERSION" -ge 87 ]; then
        cd /opt
        git clone "$REPOSITORY_URL"
        cd ensembl-vep
        git checkout "release/$VEP_VERSION"

        # Auto install (a)pi
        perl INSTALL.pl --DESTDIR "$VEP_DIR" --AUTO a --NO_HTSLIB --NO_UPDATE

        # Human reference first.  37 and 38 are included
        HUMAN_REFERENCES=( GRCh37 GRCh38 )
        for REFERENCE in "${HUMAN_REFERENCES[@]}"
        do
            if [ ! -f "/tmp/homo_sapiens_vep_${VEP_VERSION}_${REFERENCE}.tar.gz" ]; then
                echo "/tmp/homo_sapiens_vep_${VEP_VERSION}_${REFERENCE}.tar.gz does not exist"
                download_homo_sapiens_file ${VEP_VERSION} ${REFERENCE}
            fi

            # Auto install (c)ache, and (f)asta
            tar --directory "$VEP_CACHE_DIR"  -xf "/tmp/homo_sapiens_vep_${VEP_VERSION}_$REFERENCE.tar.gz"
            perl INSTALL.pl --DESTDIR "$VEP_DIR" --CACHEDIR "$VEP_DIR"/cache --CACHEURL "$VEP_CACHE_DIR" \
                    --AUTO cf --SPECIES homo_sapiens --ASSEMBLY "$REFERENCE" --NO_HTSLIB --NO_UPDATE
            rm "/tmp/homo_sapiens_vep_${VEP_VERSION}_$REFERENCE.tar.gz"
        done

        # Rat (c)ache and (f)asta
        if [ -f "/tmp/rattus_norvegicus_vep_${VEP_VERSION}_Rnor_6.0.tar.gz" ]; then
            tar --directory "$VEP_CACHE_DIR"  -xf "/tmp/rattus_norvegicus_vep_${VEP_VERSION}_Rnor_6.0.tar.gz"
            perl INSTALL.pl --DESTDIR "$VEP_DIR" --CACHEDIR "$VEP_DIR"/cache --CACHEURL "$VEP_CACHE_DIR" \
                    --AUTO cf --SPECIES rattus_norvegicus --ASSEMBLY Rnor_6.0 --NO_HTSLIB --NO_UPDATE
            rm "/tmp/rattus_norvegicus_vep_${VEP_VERSION}_Rnor_6.0.tar.gz"
        fi

        # Zebrafish (c)ache and (f)asta
        if [ -f "/tmp/danio_rerio_vep_${VEP_VERSION}_GRCz11.tar.gz" ]; then
            tar --directory "$VEP_CACHE_DIR"  -xf "/tmp/danio_rerio_vep_${VEP_VERSION}_GRCz11.tar.gz"
            perl INSTALL.pl --DESTDIR "$VEP_DIR" --CACHEDIR "$VEP_DIR"/cache --CACHEURL "$VEP_CACHE_DIR" \
                    --AUTO cf --SPECIES danio_rerio --ASSEMBLY GRCz11 --NO_HTSLIB --NO_UPDATE
            rm "/tmp/danio_rerio_vep_${VEP_VERSION}_GRCz11.tar.gz"
        fi

        # Plugins are installed to $HOME.  Install all (p)lugins, then move to common location
        perl INSTALL.pl --AUTO p --PLUGINS all --NO_UPDATE
        mv "$HOME/.vep/Plugins" "$VEP_DIR"/
    elif [ "$VEP_VERSION" = 85 ]; then
        cpanm CGI
        python -m pip install crcmod
        # Vep 85 comes directly from the Broad Institute via Google Storage
        $GSUTIL_TARGET_DIR/gsutil/gsutil -m cp -r gs://hail-common/vep/vep/loftee "$VEP_DIR"
        $GSUTIL_TARGET_DIR/gsutil/gsutil -m cp -r gs://hail-common/vep/vep/ensembl-tools-release-85 "$VEP_DIR"
        $GSUTIL_TARGET_DIR/gsutil/gsutil -m cp -r gs://hail-common/vep/vep/loftee_data "$VEP_DIR"
        $GSUTIL_TARGET_DIR/gsutil/gsutil -m cp -r gs://hail-common/vep/vep/Plugins "$VEP_DIR"
    fi

    # Loftee for VEP GRCh37 only
    mkdir -p "$VEP_DIR"/loftee_data
    aws s3 sync "$VEP_S3_SOURCE$VEP_S3_LOFTEE_PATH" "$VEP_DIR"/loftee_data
    if [ ! -f "${VEP_DIR}/loftee_data/phylocsf_gerp.sql.gz" ]; then
        echo ""${VEP_DIR}"/loftee_data/phylocsf_gerp.sql.gz does not exist"
        wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh37/phylocsf_gerp.sql.gz -P ${VEP_DIR}/loftee_data
        aws s3 cp ${VEP_DIR}/loftee_data/phylocsf_gerp.sql.gz "${VEP_S3_SOURCE}${VEP_S3_LOFTEE_PATH}/"
    fi
    gunzip "$VEP_DIR"/loftee_data/phylocsf_gerp.sql.gz

    # # Update below once Loftee is fixed for GRCh38
    # # Loftee for VEP GRCh38
    # mkdir -p "$VEP_DIR"/loftee_data/h38/
    # wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh38/loftee.sql.gz -P ${VEP_DIR}/loftee_data/h38
    # wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh38/gerp_conservation_scores.homo_sapiens.GRCh38.bw -P ${VEP_DIR}/loftee_data/h38
    # wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh38/human_ancestor.fa.gz -P ${VEP_DIR}/loftee_data/h38
    # wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh38/human_ancestor.fa.gz.fai -P ${VEP_DIR}/loftee_data/h38
    # wget https://personal.broadinstitute.org/konradk/loftee_data/GRCh38/human_ancestor.fa.gz.gzi -P ${VEP_DIR}/loftee_data/h38
    # # aws s3 sync "$VEP_DIR"/loftee_data/h38 "$VEP_S3_SOURCE$VEP_S3_LOFTEE_PATH/h38/"
    # gunzip "$VEP_DIR"/loftee_data/h38/loftee.sql.gz
}

if [ "$VEP_VERSION" != "none" ]; then
    install_prereqs
    gsutil_install
    vep_install

    # Cleanup
    rm -rf /root/.cpanm
    rm -rf /root/.vep
    rm -rf /root/ensembl-vep
else
    echo "VEP_VERSION environment variable was \"none\".  Skipping VEP installation."
fi
