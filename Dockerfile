FROM ubuntu:24.04

RUN apt-get update && \
	apt-get install -y \
		iproute2 \
		iputils-ping \
		iptables \
		conntrack \
		net-tools \
		dnsutils \
		curl \
		tcpdump \
		procps && \
	rm -rf /var/lib/apt/lists/*

CMD ["sleep", "infinity"]
