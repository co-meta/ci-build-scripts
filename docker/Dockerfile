# Ubuntu 18.04 based Yocto build environment
ARG BASELINE
FROM ${BASELINE}

ARG TZ_DATA
RUN /bin/bash -c "debconf-set-selections <<<\"${TZ_DATA}\""
RUN /usr/bin/apt-get update && /usr/bin/apt-get upgrade

ARG EXTRA_PACKAGES
ARG DEBIAN_FRONTEND=noninteractive
ARG DEBCONF_NONINTERACTIVE_SEEN=true
RUN /usr/bin/apt-get install -y ${EXTRA_PACKAGES}

RUN /usr/sbin/locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
