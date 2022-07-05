#!/bin/bash
#
# htslib is required for samtools
# develop is the default branch for the htslib repo
#

set -xe

REPOSITORY_URL="https://github.com/samtools/htslib.git"

yum -y install \
    autoconf \
    bzip2-devel \
    gcc72 \
    git \
    libcurl \
    libcurl-devel \
    openssl-devel \
    xz-devel \
    zlib-devel 

# Added due to gcc failure in Amazon Linux 2 AMI.
# error: no acceptable C compiler found in $PATH
yum -y groupinstall "Development Tools"

if [ -z "$HTSLIB_VERSION" ]; then
    HTSLIB_VERSION="develop";
    echo "HTSLIB_VERSION was empty.  Setting to develop."
fi

mkdir -p /opt
cd /opt
git clone "$REPOSITORY_URL"
cd htslib
git checkout "$HTSLIB_VERSION"
autoheader
autoconf
./configure
make -j "$(grep -c ^processor /proc/cpuinfo)"
make install

# htslib source is not removed as it's used during the VEP build