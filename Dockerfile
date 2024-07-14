FROM ubuntu:jammy-20240227@sha256:77906da86b60585ce12215807090eb327e7386c8fafb5402369e421f44eff17e as base
WORKDIR /app

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get install -y curl unzip ca-certificates zip  tzdata wget gnupg2 bzip2 apt-transport-https lsb-release git   python3-crcmod python3-openssl --no-install-recommends  && \
  apt-get clean

RUN apt-get update && apt-get upgrade -y && \
  rm -Rf /var/lib/apt/lists/* && \
  apt-get clean

# stern, jq, yq
RUN curl -sLS https://get.arkade.dev | sh && \ 
  arkade get kubectl stern jq yq --path /usr/bin && \
  chmod +x /usr/bin/kubectl /usr/bin/stern /usr/bin/jq /usr/bin/yq

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
copy --from=gcloud-installer /opt/google-cloud-sdk /opt/google-cloud-sdk
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
