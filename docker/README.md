# Codex Docker Image

Build and run using the example docker-compose file:
`docker-compose up -d`

Stop and retain image and volume data:
`docker-compose down`

Stop and delete image and volume data:
`docker-compose down --rmi all -v`
`rm -R hostdatadir`

# Environment variables
Codex docker image supports environment variables for each CLI argument:
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

Environment variable `API_PORT` is required. Other variables are optional and will default to Codex's CLI default values.

# Useful
Connect nodes with the `/connect` endpoint.
To get the IP address of a container within a network:
Find container Id: `docker ps`
Open terminal in container: `docker exec -it <CONTAINER ID> sh`
Get IP addresses: `ifconfig`
