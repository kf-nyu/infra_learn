# OSIRIS Lab Infrastructure Team Tutorial

Hands-on infrastructure exercises for the OSIRIS Lab Infrastructure Team.

## Task 1: Internal Server and Gateway

Task 1 uses its own Compose project in `task1/`. Its networks, container names, and subnets are separate from Task 2, so both labs can run at the same time.

Set up two Ubuntu containers:

- **Internal server** — connected only to the private network
- **Gateway server** — connected to both the private and external networks

The internal server routes external traffic through the gateway. The gateway uses IP forwarding and NAT (MASQUERADE) to provide external connectivity.

## Test

1. Start only the internal server.
2. Verify that the internal server cannot reach `1.1.1.1`.
3. Start the gateway server.
4. Verify that the same internal server can now reach `1.1.1.1`.

Run the automated test with:

```bash
cd task1 && ./test_gateway.sh
```
### GitHub Actions Note

GitHub-hosted runners do not reliably support outbound ICMP (`ping`). Therefore, the automated CI test uses HTTPS with `curl` instead of `ping`.

The same connectivity test is used before and after starting the gateway:

1. With the gateway **off**, HTTPS access from the internal server must fail.
2. With the gateway **on**, the same HTTPS request must succeed.

This verifies that external connectivity is provided through the gateway while keeping the CI test compatible with GitHub-hosted runners.

## Task 2: Private App and Reverse Proxy

Task 2 uses its own Compose project in `task2/`. Its networks, container names, and subnets are separate from Task 1, so both labs can run at the same time.

- **Internal app** — Flask app built from `task2/Dockerfile`, on a completely private network (`internal: true`), with no published ports
- **Proxy** — nginx on both the private network and an external network. It is the only path to the app

## Test

1. Send an HTTP request to the internal app from the external network and receive nothing.
2. Send an HTTP request to the proxy and receive the app response.

Run the automated test with:

```bash
cd task2 && ./test_proxy.sh
```

From the host, the app is also available through the proxy at `http://127.0.0.1:8080/`.
