docker:
	docker build -t package-mcollective-puppet-update .

test: docker
	docker run -v `pwd`:/src package-mcollective-puppet-update /src/test.sh

deb: docker
	docker run -v `pwd`:/src \
             -e "BUILD_NUMBER=${BUILD_NUMBER}" \
             package-mcollective-puppet-update \
             /src/build.sh

all: test deb
