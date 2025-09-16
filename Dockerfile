FROM ubuntu:noble@sha256:590e57acc18d58cd25d00254d4ca989bbfcd7d929ca6b521892c9c904c391f50 AS installer-env
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ENV PS_VERSION=7.4.4

RUN --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/var/cache/apt \
    apt-get update \
    && apt-get install --no-install-recommends -y  curl less locales ca-certificates && \
    ARCH=${TARGETARCH} && \
    if [ "${TARGETARCH}" = "amd64" ]; then ARCH="x64"; fi && \
    curl -L -o /tmp/powershell.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v${PS_VERSION}/powershell-${PS_VERSION}-linux-${ARCH}.tar.gz

FROM ubuntu:noble@sha256:590e57acc18d58cd25d00254d4ca989bbfcd7d929ca6b521892c9c904c391f50 AS base
WORKDIR /app

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get install -y curl unzip ca-certificates zip tzdata wget gnupg2 bzip2 apt-transport-https locales locales-all lsb-release git python3-crcmod python3-openssl --no-install-recommends  && \
  update-ca-certificates && \
  apt-get clean

RUN apt-get update && apt-get upgrade -y && \
  rm -Rf /var/lib/apt/lists/* && \
  apt-get clean

RUN locale-gen en_US.UTF-8
RUN update-locale LANG=en_US.UTF-8

# stern, jq, yq
RUN curl -sLS https://get.arkade.dev | sh && \
  arkade get kubectl stern jq yq sops flux helm kustomize --path /usr/bin && \
  /bin/bash -c "chmod +x /usr/bin/{kubectl,stern,jq,yq,sops,flux,helm,kustomize}"

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -L "https://github.com/brocode/fblog/releases/latest/download/fblog" -o /usr/bin/fblog && \
        chmod +x /usr/bin/fblog; \
    else \
        echo "fblog binary not available for $ARCH, building from source..." && \
        apt-get update && apt-get install -y build-essential --no-install-recommends && \
        curl https://sh.rustup.rs -sSf | sh -s -- -y && \
        $HOME/.cargo/bin/cargo install fblog && \
        mv $HOME/.cargo/bin/fblog /usr/bin/fblog && \
        apt-get autoremove build-essential -y && \
        apt-get clean && \
        $HOME/.cargo/bin/rustup self uninstall -y; \
    fi


ARG POWERSHELL_VERSION=7.4.4

# Define ENVs for Localization/Globalization
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV PS_INSTALL_FOLDER=/opt/powershell
ENV POWERSHELL_TELEMETRY_OPTOUT=1
ENV PSModuleAnalysisCachePath=/var/cache/microsoft/powershell/PSModuleAnalysisCache/ModuleAnalysisCache
ENV PS_VERSION=7.4.4
RUN --mount=from=installer-env,target=/mnt/pwsh,source=/tmp \
    --mount=type=cache,target=/var/lib/apt \
    --mount=type=cache,target=/var/cache/apt \
    apt-get update  && \
    apt-get install -y --no-install-recommends \
      less locales \
      gss-ntlmssp \
      libicu74 \
      libssl3 \
      libc6 \
      libgcc1 \
      libgssapi-krb5-2 \
      liblttng-ust1 \
      libstdc++6 \
      zlib1g && \
    mkdir -p /opt/powershell && \
    tar zxf /mnt/pwsh/powershell.tar.gz -C /opt/powershell && \
    chmod +x /opt/powershell/pwsh && \
    ln -s /opt/powershell/pwsh /usr/bin/pwsh && \
    # install module outsize of powershell due to segfaults on emulated arm
    curl -L -o powershell-yaml.nupkg https://www.powershellgallery.com/api/v2/package/powershell-yaml/0.4.7  && \
    mkdir -p $HOME/.local/share/powershell/Modules/powershell-yaml/0.4.7 && \
    unzip powershell-yaml.nupkg -x */.rels *.nuspec *.xml -d $HOME/.local/share/powershell/Modules/powershell-yaml/0.4.7 && \
    rm powershell-yaml.nupkg && \
    apt-get clean

# Minimalized Google cloud sdk
FROM base AS gcloud-installer

ENV GCLOUD_PATH=/opt/google-cloud-sdk
ENV PATH=$GCLOUD_PATH/bin:$PATH
ENV CLOUDSDK_PYTHON=/usr/bin/python3
# Download and install cloud sdk. Review the components I install, you may not need them.
RUN GCLOUDCLI_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz" && \
if [ "${TARGETARCH}" = "arm64" ]; then \
  GCLOUDCLI_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-arm.tar.gz"; \
fi && \
    curl $GCLOUDCLI_URL -o gcloud.tar.gz && \
    tar xzf gcloud.tar.gz -C /opt && \
    rm gcloud.tar.gz && \
    rm -rf $GCLOUD_PATH/platform/bundledpythonunix && \
    gcloud config set core/disable_usage_reporting true && \
    gcloud config set component_manager/disable_update_check true && \
    gcloud config set metrics/environment github_docker_image && \
    gcloud components remove -q bq && \
    gcloud components install -q beta kubectl-oidc gke-gcloud-auth-plugin && \
    rm -rf $(find $GCLOUD_PATH/ -regex ".*/__pycache__") && \
    rm -rf $GCLOUD_PATH/.install/.backup && \
    rm -rf $GCLOUD_PATH/bin/anthoscli && \
    gcloud --version


FROM base AS final

# Install all locales
RUN locale-gen en_US.UTF-8
RUN update-locale LANG=en_US.UTF-8

RUN apt-get install -y locales locales-all

ENV PATH=/opt/google-cloud-sdk/bin:$PATH
ENV CLOUDSDK_PYTHON=/usr/bin/python3
COPY --from=gcloud-installer /opt/google-cloud-sdk /opt/google-cloud-sdk
# This is to be able to update gcloud packages
RUN git config --system credential.'https://source.developers.google.com'.helper gcloud.sh

# Azure CLI
RUN apt-get update && apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg lsb-release && \
  mkdir -p /etc/apt/keyrings && \
  curl -sLSk https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null && \
  chmod go+r /etc/apt/keyrings/microsoft.gpg

RUN AZ_DIST=$(lsb_release -cs) && \
  echo "Types: deb" > /etc/apt/sources.list.d/azure-cli.sources && \
  echo "URIs: https://packages.microsoft.com/repos/azure-cli/" >> /etc/apt/sources.list.d/azure-cli.sources && \
  echo "Suites: ${AZ_DIST}" >> /etc/apt/sources.list.d/azure-cli.sources && \
  echo "Components: main" >> /etc/apt/sources.list.d/azure-cli.sources && \
  echo "Architectures: $(dpkg --print-architecture)" >> /etc/apt/sources.list.d/azure-cli.sources && \
  echo "Signed-by: /etc/apt/keyrings/microsoft.gpg" >> /etc/apt/sources.list.d/azure-cli.sources && \
  apt-get update && apt-get install -y --no-install-recommends azure-cli

# AWS CLI
RUN AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" && \
  if [ "${TARGETARCH}" = "arm64" ]; then \
    AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
  fi && \
  curl "${AWSCLI_URL}" -o "awscliv2.zip" && \
  unzip -q awscliv2.zip && ./aws/install -i /opt/aws -b /usr/bin/ && \
  rm awscliv2.zip && \
  rm -rf ./aws && \
  aws --version
