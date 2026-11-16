# Extends the exact inspected builder recipe; build and consumption share Debian13.
ARG SDK_BASE=pd-csd-sdk-base
FROM ${SDK_BASE}
USER root
RUN sed 's/^Types: deb$/Types: deb-src/' /etc/apt/sources.list.d/debian.sources > /etc/apt/sources.list.d/pd-source.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends libxrender-dev libxfixes-dev gcc libc6-dev dpkg-dev file binutils openssl libunwind8 \
      libfontconfig-dev libglib2.0-dev xvfb xauth x11-utils fonts-dejavu-core squashfs-tools desktop-file-utils bubblewrap xdotool imagemagick patchelf
# Keep matching binary/source indexes for exact apt-get source versions.
ARG CI_UID=1001
ARG CI_GID=1001
RUN (getent group "$CI_GID" >/dev/null || groupadd --gid "$CI_GID" pd-csd-ci) \
 && useradd --uid "$CI_UID" --gid "$CI_GID" --create-home pd-csd-ci
ENV HOME=/home/pd-csd-ci
USER ${CI_UID}:${CI_GID}
