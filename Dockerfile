FROM ubuntu:jammy-20240227@sha256:77906da86b60585ce12215807090eb327e7386c8fafb5402369e421f44eff17e
WORKDIR /app
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
  apt-get install -y curl unzip ca-certificates jq  tzdata wget gnupg2 bzip2 apt-transport-https lsb-release git --no-install-recommends  && \
  apt-get clean

RUN apt-get update && apt-get upgrade -y && \
  rm -Rf /var/lib/apt/lists/* && \
  apt-get clean

RUN curl -sLS https://get.arkade.dev | sh && arkade get kubectl stern jq yq --path /usr/bin

RUN mkdir -p /etc/apt/keyrings && \
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null && \
  chmod go+r /etc/apt/keyrings/microsoft.gpg &&  \
  echo "deb [arch=`dpkg --print-architecture` signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azure-cli.list && \
  cat /etc/apt/sources.list.d/azure-cli.list && \
  apt-get update && \
  apt-get install -y azure-cli && \
  apt-get clean

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
  unzip -q awscliv2.zip && ./aws/install -i ${HOME}/aws -b ${HOME}/bin/ && \
  rm awscliv2.zip

RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && apt-get update -y && apt-get install google-cloud-sdk google-cloud-cli google-cloud-cli-kubectl-oidc -y  &&  apt-get clean


