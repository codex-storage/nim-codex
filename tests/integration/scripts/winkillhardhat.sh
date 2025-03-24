#!/bin/bash

# List all node.exe processes with command line arguments
list_node_processes() {
  powershell.exe -Command "Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize"
}

# Find node processes containing vendor\codex-contracts-eth in command line
find_vendor_node_processes() {
  echo "Looking for node processes with 'vendor\\codex-contracts-eth' in command line..."
  powershell.exe -Command "Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Where-Object { \$_.CommandLine -match 'vendor\\\\codex-contracts-eth' } | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize"
}

# Find node processes running on a specific port
find_node_by_port() {
  local port=$1
  echo "Looking for node processes running on port $port..."
  powershell.exe -Command "Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Where-Object { \$_.CommandLine -match '--port $port' } | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize"
}

# Kill all node.exe processes containing vendor\codex-contracts-eth
kill_vendor_node_processes() {
  echo "Finding and killing node.exe processes containing 'vendor\\codex-contracts-eth'..."
  powershell.exe -Command "
    \$processes = Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Where-Object { \$_.CommandLine -match 'vendor\\\\codex-contracts-eth' };
    if (\$processes) {
      foreach (\$process in \$processes) {
        Stop-Process -Id \$process.ProcessId -Force;
        Write-Host \"Killed process \$(\$process.ProcessId)\";
      }
    } else {
      Write-Host \"No matching node.exe processes found\";
    }
  "
}

# Kill node.exe process running on a specific port
kill_node_by_port() {
  local port=$1
  echo "Finding and killing node.exe process running on port $port..."
  powershell.exe -Command "
    \$processes = Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Where-Object { \$_.CommandLine -match '--port $port' };
    if (\$processes) {
      foreach (\$process in \$processes) {
        Stop-Process -Id \$process.ProcessId -Force;
        Write-Host \"Killed process \$(\$process.ProcessId) running on port $port\";
      }
    } else {
      Write-Host \"No node.exe process found running on port $port\";
    }
  "
}

# Kill node.exe process with both vendor string and specific port
kill_vendor_node_by_port() {
  local port=$1
  echo "Finding and killing node.exe process with 'vendor\\codex-contracts-eth' running on port $port..."
  powershell.exe -Command "
    \$processes = Get-WmiObject Win32_Process -Filter \"name = 'node.exe'\" | Where-Object { \$_.CommandLine -match 'vendor\\\\codex-contracts-eth' -and \$_.CommandLine -match '--port $port' };
    if (\$processes) {
      foreach (\$process in \$processes) {
        Stop-Process -Id \$process.ProcessId -Force;
        Write-Host \"Killed process \$(\$process.ProcessId) running on port $port\";
      }
    } else {
      Write-Host \"No matching node.exe process found running on port $port\";
    }
  "
}

# Check if being run directly or sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If run directly (not sourced), provide command line interface
  case "$1" in
    list)
      list_node_processes
      ;;
    find)
      find_vendor_node_processes
      ;;
    findport)
      if [ -z "$2" ]; then
        echo "Usage: $0 findport PORT_NUMBER"
        exit 1
      fi
      find_node_by_port "$2"
      ;;
    killall)
      kill_vendor_node_processes
      ;;
    killport)
      if [ -z "$2" ]; then
        echo "Usage: $0 killport PORT_NUMBER"
        exit 1
      fi
      kill_node_by_port "$2"
      ;;
    killvendorport)
      if [ -z "$2" ]; then
        echo "Usage: $0 killvendorport PORT_NUMBER"
        exit 1
      fi
      kill_vendor_node_by_port "$2"
      ;;
    *)
      echo "Usage: $0 {list|find|findport PORT|killall|killport PORT|killvendorport PORT}"
      exit 1
      ;;
  esac
fi