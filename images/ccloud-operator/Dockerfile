FROM flant/shell-operator:v1.0.0-beta.12

RUN apt-get update && apt-get install -y curl

RUN curl -L --http1.1 https://cnfl.io/ccloud-cli | sh -s -- -b /usr/bin v1.16.0

RUN wget https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl -O /bin/kubectl && chmod +x /bin/kubectl

ADD hooks /hooks
