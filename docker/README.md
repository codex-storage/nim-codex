# Codex Docker Image

Build and run using the example docker-compose file:
`docker-compose up -d`

Stop and retain image and volume data:
`docker-compose down`

Stop and delete image and volume data:
`docker-compose down --rmi all -v`
`rm -R hostdatadir`


# Useful
Connect nodes with the `/connect` endpoint.
To get the IP address of a container within a network:
Find container Id: `docker ps`
Open terminal in container: `docker exec -it <CONTAINER ID> sh`
Get IP addresses: `ifconfig`
