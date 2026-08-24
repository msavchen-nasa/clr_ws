# Set desired ROS distribution
ARG ROS_DISTRO=jazzy

# The base image for the overlay deployment
ARG CLR_WS_BASE_IMAGE_TAG="jazzy-devel"
ARG CLR_WS_BASE_IMAGE="nasajscrobotics/clr_ws"
ARG CLR_WS_BASE_IMAGE="${CLR_WS_BASE_IMAGE}:${CLR_WS_BASE_IMAGE_TAG}"

# This layer grabs package manifests from the src directory for preserving rosdep installs.
# This can significantly speed up rebuilds for the base package when src contents have changed.
FROM alpine:latest AS package-manifests

# Copy in the src directory, then remove everything that isn't a manifest or an ignore file.
COPY src/ /src/
RUN find /src -type f ! -name "package.xml" ! -name "COLCON_IGNORE" -delete && \
    find /src -type d -empty -delete

# Throw away for an empty source directory
RUN mkdir -p /src

# Using the pre-compiled ROS images as the base.
FROM ros:${ROS_DISTRO} AS er4-dev

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Overridable non root user information.
ARG USER_UID=1000
ARG USER_GID=1000
ARG USERNAME=er4-user

# Define the install location for the developing application
ENV ER4_WS="/home/er4-user/ws"

# DEBIAN_FRONTEND is set as an ARG instead of ENV variable so it doesn't persist in the image after build
ARG DEBIAN_FRONTEND=noninteractive

# As of 24.04, many Ubuntu modules will check for FIPS kernels and adjust packages accordingly. This
# can break in the container, which shares a kernel but does not have FIPS packages installed. So
# in the running image we ensure that SSL at does not cause problems when downloading or making
# secure connections during the build.
ENV OPENSSL_FORCE_FIPS_MODE=0

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -q -y \
    bash-completion \
    ccache \
    gdb \
    gdbserver \
    git \
    less \
    python3-colcon-clean \
    python3-colcon-common-extensions \
    python3-colcon-mixin \
    python3-pip \
    python3-rosdep \
    python3-vcstool \
    software-properties-common \
    terminator \
    tmux \
    vim \
    xterm \
    wget

# Add a non-root user with provided user details. Some images have a default `ubuntu` user, so we remove it before adding the
# new one.
RUN userdel -r ubuntu 2>/dev/null || true
RUN groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -l -u ${USER_UID} -g ${USER_GID} --create-home -m -s /bin/bash -G sudo,adm,dialout,dip,plugdev,video ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p \
        /home/${USERNAME}/.ccache \
        /home/${USERNAME}/.colcon \
        /home/${USERNAME}/.ros \
        /home/${USERNAME}/.bash \
        ${ER4_WS}/src \
        ${ER4_WS}/build \
        ${ER4_WS}/install \
        ${ER4_WS}/log && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# Install nanobind from pip rather than rosdep, and include additional deps for the mujoco conversion process.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    pip3 install nanobind mujoco==3.4.0 obj2mjcf trimesh pycollada

# Setup the install directory and copy the workspace to it.
# We could alternatively copy package manifests to preserve the layer cache if the build duration becomes too onerous.
USER ${USERNAME}
WORKDIR  ${ER4_WS}

# Copy package manifests for installing rosdeps
COPY --chown=${USERNAME}:${USERNAME} --from=package-manifests /src/ ./src

# Install rosdeps
# Init is unnecessary if using the ROS base image
# RUN sudo rosdep init && rosdep update --rosdistro ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt update && \
    . /opt/ros/${ROS_DISTRO}/setup.bash && \
    rosdep update && \
    rosdep install -iry --from-paths src

# Install extra ROS deps
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && \
    sudo apt-get install -q -y \
    ros-${ROS_DISTRO}-ros2controlcli \
    ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
    ros-${ROS_DISTRO}-rmw-fastrtps-cpp \
    ros-${ROS_DISTRO}-plotjuggler-ros

# Copy in the remainder of the src directory
COPY --chown=${USERNAME}:${USERNAME} src/ src/

# Setup colcon default mixins and add default settings
RUN colcon mixin add default \
    https://raw.githubusercontent.com/colcon/colcon-mixin-repository/master/index.yaml && \
    colcon mixin update || true
RUN colcon metadata add default  \
    https://raw.githubusercontent.com/colcon/colcon-metadata-repository/master/index.yaml && \
    colcon metadata update || true

# Configure pyassimp, which has some unique problems on aarch machines.
# To address this, we have adjusted the $LD_LIBRARY_PATH in the entrypoint to ensure
# the required path is available to the python module to load the library.
RUN pip3 install pyassimp==4.1.3

# copy in configs for different features
COPY --chown=${USERNAME}:${USERNAME} config/colcon-defaults.yaml /home/${USERNAME}/.colcon/defaults.yaml
COPY --chown=${USERNAME}:${USERNAME} config/terminator_config /home/${USERNAME}/.config/terminator/config

# Setup entrypoint and ensure it's added to ~/.bashrc
COPY scripts/entrypoint.sh /entrypoint.sh
RUN echo "source /entrypoint.sh" >> ~/.bashrc

# Make it obvious when operating in a container
RUN echo "PS1=\"${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\](docker):\[\033[01;34m\]\w\[\033[00m\]\$ \"" >> ~/.bashrc

ENTRYPOINT ["/entrypoint.sh"]

# Source built dev image for automated testing.
FROM er4-dev AS er4-dev-source

RUN . /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build

FROM ${CLR_WS_BASE_IMAGE} AS er4-demo

ARG USERNAME
ARG USER_UID
ARG USER_GID

USER root

RUN OLD_UID=$(id -u ${USERNAME}) && \
    OLD_GID=$(id -g ${USERNAME}) && \
    if [ "${OLD_UID}" != "${USER_UID}" ] || [ "${OLD_GID}" != "${USER_GID}" ]; then \
        sed -i "s/^\(${USERNAME}:[^:]*:\)[^:]*:[^:]*:/\1${USER_UID}:${USER_GID}:/" /etc/passwd && \
        sed -i "s/^\(${USERNAME}:[^:]*:\)[^:]*:/\1${USER_GID}:/" /etc/group && \
        find /home/${USERNAME} \
            \( -user ${OLD_UID} -o -group ${OLD_GID} \) \
            -print0 | xargs -0 -P $(nproc) -n 1000 chown ${USER_UID}:${USER_GID}; \
    fi

USER ${USERNAME}

FROM ros:${ROS_DISTRO} AS er4-cmoda-dev

# "Building Image for CMO-DA"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Overridable non root user information.
ARG USER_UID=1000
ARG USER_GID=1000
ARG USERNAME=er4-user

# Define the install location for the developing application
ENV CMODA_WS="/home/er4-user"

# DEBIAN_FRONTEND is set as an ARG instead of ENV variable so it doesn't persist in the image after build
ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -q -y \
    bash-completion \
    ccache \
    gdb \
    gdbserver \
    git \
    less \
    python3-pip \
    python3-rosdep \
    software-properties-common \
    terminator \
    tmux \
    vim \
    xterm \
    wget \
    npm \ 
    libnspr4 \
    libasound2t64 \
    libnss3 \
    unzip 

    # ros2 launch rosbridge_server rosbridge_websocket.launch.py

# Add a non-root user with provided user details. Some images have a default `ubuntu` user, so we remove it before adding the
# new one.
RUN userdel -r ubuntu 2>/dev/null || true
RUN groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -l -u ${USER_UID} -g ${USER_GID} --create-home -m -s /bin/bash -G sudo,adm,dialout,dip,plugdev,video ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p ${CMODA_WS}/cmoda && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# Setup the install directory and copy the workspace to it.
# We could alternatively copy package manifests to preserve the layer cache if the build duration becomes too onerous.
USER ${USERNAME}
WORKDIR ${CMODA_WS}

ENV NVM_DIR /home/${USERNAME}/.nvm

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install 22

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && echo ". $HOME/.local/bin/env" >> ~/.bashrc

ENV PATH="${CMODA_WS}/.local/bin/:$PATH"

# copy in configs for different features
COPY --chown=${USERNAME}:${USERNAME} config/terminator_config /home/${USERNAME}/.config/terminator/config

# Make it obvious when operating in a container
RUN echo "PS1=\"${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\](docker):\[\033[01;34m\]\w\[\033[00m\]\$ \"" >> ~/.bashrc

WORKDIR ${CMODA_WS}/cmoda/ros-mcp-server

FROM er4-dev AS er4-vla-dev

RUN echo "Building docker for VLAs"


RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && \
    sudo apt-get install -q -y \
    git-lfs

WORKDIR  ${ER4_WS}/src/vla/Lerobot-MujoCo

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    pip install -r requirements.txt

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    && sudo dpkg -i cuda-keyring_1.1-1_all.deb \
    && sudo apt-get update \
    && sudo apt-get -y install cuda-toolkit-12-8

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    pip install flash-attn==2.7.3 --no-build-isolation
