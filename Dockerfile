FROM docker-dev.yelpcorp.com/trusty_yelp:latest

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git ruby ruby-dev mcollective-omnibus=2.8.8-77 git \
        devscripts build-essential fakeroot debhelper cdbs dpatch \
    && apt-get clean

RUN gem install bundler

RUN mkdir /src
ADD Gemfile /src/Gemfile
WORKDIR /src
RUN bundle install
