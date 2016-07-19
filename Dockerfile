FROM ubuntu:trusty

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         python-software-properties software-properties-common \
    && add-apt-repository ppa:git-core/ppa -y

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git ruby ruby-dev mcollective mcollective-client \
        devscripts build-essential fakeroot debhelper cdbs dpatch \
    && apt-get clean
RUN gem install bundler

RUN mkdir /src
ADD Gemfile /src/Gemfile
WORKDIR /src
RUN bundle install