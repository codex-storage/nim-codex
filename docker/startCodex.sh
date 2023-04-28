echo "Starting Codex..."

args=""

## local ip as NAT?
do_nat=$(hostname -i)
echo "got nat:$do_nat"

# Required arguments
if [ -n "$LISTEN_ADDRS" ]; then
  echo "Listen address: $LISTEN_ADDRS"
  args="$args --listen-addrs=$LISTEN_ADDRS"
else
  args="$args --listen-addrs=/ip4/0.0.0.0/tcp/8071"
fi

if [ -n "$API_BINDADDR" ]; then
  echo "API bind address: $API_BINDADDR"
  args="$args --api-bindaddr=$API_BINDADDR"
else
  args="$args --api-bindaddr=0.0.0.0"
fi

if [ -n "$DATA_DIR" ]; then
  echo "Data dir: $DATA_DIR"
  args="$args --data-dir=$DATA_DIR"
else
  args="$args --data-dir=/datadir"
fi

# Optional arguments
# Log level
if [ -n "$LOG_LEVEL" ]; then
  echo "Log level: $LOG_LEVEL"
  args="$args --log-level=$LOG_LEVEL"
fi

# Metrics
if [ -n "$METRICS_ADDR" ] && [ -n "$METRICS_PORT" ]; then
    echo "Metrics enabled"
    args="$args --metrics=true"
    args="$args --metrics-address=$METRICS_ADDR"
    args="$args --metrics-port=$METRICS_PORT"
fi

# NAT
# if [ -n "$NAT_IP" ]; then
echo "NAT: $do_nat"
args="$args --nat=$do_nat"
# fi

# Discovery IP
if [ -n "$DISC_IP" ]; then
  echo "Discovery IP: $DISC_IP"
  args="$args --disc-ip=$DISC_IP"
fi

# Discovery Port
if [ -n "$DISC_PORT" ]; then
  echo "Discovery Port: $DISC_PORT"
  args="$args --disc-port=$DISC_PORT"
fi

# Net private key
if [ -n "$NET_PRIVKEY" ]; then
  echo "Network Private Key path: $NET_PRIVKEY"
  args="$args --net-privkey=$NET_PRIVKEY"
fi

# Bootstrap SPR
if [ -n "$BOOTSTRAP_SPR" ]; then
  echo "Bootstrap SPR: $BOOTSTRAP_SPR"
  args="$args --bootstrap-node=$BOOTSTRAP_SPR"
fi

# Max peers
if [ -n "$MAX_PEERS" ]; then
  echo "Max peers: $MAX_PEERS"
  args="$args --max-peers=$MAX_PEERS"
fi

# Agent string
if [ -n "$AGENT_STRING" ]; then
  echo "Agent string: $AGENT_STRING"
  args="$args --agent-string=$AGENT_STRING"
fi

# API port
if [ -n "$API_PORT" ]; then
  echo "API port: $API_PORT"
  args="$args --api-port=$API_PORT"
fi

# Storage quota
if [ -n "$STORAGE_QUOTA" ]; then
  echo "Storage quote: $STORAGE_QUOTA"
  args="$args --storage-quota=$STORAGE_QUOTA"
fi

# Block TTL
if [ -n "$BLOCK_TTL" ]; then
  echo "Block TTL: $BLOCK_TTL"
  args="$args --block-ttl=$BLOCK_TTL"
fi

# Cache size
if [ -n "$CACHE_SIZE" ]; then
  echo "Cache size: $CACHE_SIZE"
  args="$args --cache-size=$CACHE_SIZE"
fi

# Ethereum persistence
if [ -n "$ETH_PROVIDER" ] && [ -n "$ETH_ACCOUNT" ] && [ -n "$ETH_MARKETPLACE_ADDRESS" ]; then
    echo "Persistence enabled"
    args="$args --persistence"
    args="$args --eth-provider=$ETH_PROVIDER"
    args="$args --eth-account=$ETH_ACCOUNT"
    # args="$args --validator"

    # Remove this as soon as CLI option is available:
    echo "{\"contracts\": { \"Marketplace\": { \"address\": \""$ETH_MARKETPLACE_ADDRESS"\" } } }" > /root/marketplace_address.json
    args="$args --eth-deployment=/root/marketplace_address.json"

    if [ -n "$SIMULATE_PROOF_FAILURES" ]; then
      echo "Simulate proof failures: $SIMULATE_PROOF_FAILURES"
      args="$args --simulate-proof-failures=$SIMULATE_PROOF_FAILURES"
    fi
fi

echo "./codex $args"
/bin/bash -l -c "./codex $args"
