FROM ubuntu:jammy-20240227@sha256:77906da86b60585ce12215807090eb327e7386c8fafb5402369e421f44eff17e AS installer-env
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

FROM ubuntu:jammy-20240227@sha256:77906da86b60585ce12215807090eb327e7386c8fafb5402369e421f44eff17e as base
WORKDIR /app

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get install -y curl unzip ca-certificates zip tzdata wget gnupg2 bzip2 apt-transport-https lsb-release git python3-crcmod python3-openssl --no-install-recommends  && \
  apt-get clean

RUN apt-get update && apt-get upgrade -y && \
  rm -Rf /var/lib/apt/lists/* && \
  apt-get clean

# stern, jq, yq
RUN curl -sLS https://get.arkade.dev | sh && \
  arkade get kubectl stern jq yq sops --path /usr/bin && \
  chmod +x /usr/bin/kubectl /usr/bin/stern /usr/bin/jq /usr/bin/yq /usr/bin/sops

RUN apt-get update && apt-get install -y build-essential --no-install-recommends && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y && \
    $HOME/.cargo/bin/cargo install fblog && \
    mv $HOME/.cargo/bin/fblog /usr/bin/fblog && \
    apt-get autoremove build-essential -y && \
    apt-get clean && \
    $HOME/.cargo/bin/rustup self uninstall -y

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
      libicu70 \
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
    curl -L -o powershell-yaml.nupkg https://psg-prod-eastus.azureedge.net/packages/powershell-yaml.0.4.7.nupkg  && \
    mkdir -p $HOME/.local/share/powershell/Modules/powershell-yaml/0.4.7 && \
    unzip powershell-yaml.nupkg -x */.rels *.nuspec *.xml -d $HOME/.local/share/powershell/Modules/powershell-yaml/0.4.7 && \
    rm powershell-yaml.nupkg && \
    apt-get clean

# Minimalized Google cloud sdk
FROM base as gcloud-installer

ENV GCLOUD_PATH=/opt/google-cloud-sdk
ENV PATH $GCLOUD_PATH/bin:$PATH
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


FROM base as final

ENV PATH /opt/google-cloud-sdk/bin:$PATH
ENV CLOUDSDK_PYTHON=/usr/bin/python3
COPY --from=gcloud-installer /opt/google-cloud-sdk /opt/google-cloud-sdk
# This is to be able to update gcloud packages
RUN git config --system credential.'https://source.developers.google.com'.helper gcloud.sh


# Azure CLI
RUN mkdir -p /etc/apt/keyrings && \
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null && \
  chmod go+r /etc/apt/keyrings/microsoft.gpg &&  \
  echo "deb [arch=`dpkg --print-architecture` signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azure-cli.list && \
  cat /etc/apt/sources.list.d/azure-cli.list && \
  apt-get update && \
  apt-get install -y azure-cli && \
  apt-get clean && \
  rm -rf $(find /opt/az -regex ".*/__pycache__") && \
  az version

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
