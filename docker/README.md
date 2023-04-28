# Codex Docker Image

Build and run using the example docker-compose file:
`docker-compose up -d`

Stop and retain image and volume data:
`docker-compose down`

Stop and delete image and volume data:
`docker-compose down --rmi all -v`
`rm -R hostdatadir`

# Building local modifications for testing
Sometimes, you just need to make a small change and build a new docker image for the purpose of testing. To speed up this process, the docker build has been cut into two steps.
Step 1: (buildsetup.bat) builds the setup.Dockerfile and takes care of the slow process of building the nim buildsystem. This does not need to be re-done for most small changes to the nim-codex codebase.
Step 2: (buildlocal.bat) builds the local.Dockerfile and pushes the new image as `thatbenbierens/codexlocal:latest`.

- The CI build cannot use this two-step speed-up because it builds images for multiple architectures, which the local scripts don't do.

# Environment variables
Codex docker image supports the following environment variables:
- LISTEN_ADDRS(*)
- API_BINDADDR(*)
- DATA_DIR(*)
- LOG_LEVEL
- METRICS_ADDR
- METRICS_PORT
- NAT_IP
- API_PORT
- DISC_IP
- DISC_PORT
- NET_PRIVKEY
- BOOTSTRAP_SPR
- MAX_PEERS
- AGENT_STRING
- STORAGE_QUOTA
- BLOCK_TTL
- CACHE_SIZE
- ETH_PROVIDER
- ETH_ACCOUNT
- ETH_DEPLOYMENT
- SIMULATE_PROOF_FAILURES

(*) These variables have default values in the docker image that are different from Codex's standard default values.

All environment variables are optional and will default to Codex's CLI default values.

# Constants
Codex CLI arguments 'data-dir', 'listen-addrs', and 'api-bindaddr' cannot be configured. They are set to values required for docker in case of bind addresses. In the case of 'data-dir', the value is set to `/datadir`. It is important that you map this folder to a host volume in your container configuration. See docker-compose.yaml for examples.

# Useful
Connect nodes with the `/connect` endpoint.
To get the IP address of a container within a network:
Find container Id: `docker ps`
Open terminal in container: `docker exec -it <CONTAINER ID> sh`
Get IP addresses: `ifconfig`

# Slim
1. Build the image using `docker build -t status-im/codexsetup:latest -f codex.Dockerfile ..`
2. The docker image can then be minifed using [slim](https://github.com/slimtoolkit/slim). Install slim on your path and then run:
```shell
slim # brings up interactive prompt
>>> build --target status-im/codexsetup --http-probe-off true
```
3. This should output an image with name `status-im/codexsetup.slim`
4. We can then bring up the image using `docker-compose up -d`.