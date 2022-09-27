FROM nimlang/nim

RUN apt-get update -qq && \
    DEBIAN_FRONTEND="noninteractive" apt-get install -yq cmake curl make && \
    rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*
