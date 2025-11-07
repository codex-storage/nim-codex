#!/bin/bash

# List all processes with a specific name
list() {
  local name=$1
  echo "Listing all processes named '$name'..."
  powershell.exe -Command "Get-CimInstance Win32_Process -Filter \"name = '$name'\" | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize"
}

# Search for processes with a specific name and command line pattern
search() {
  local name=$1
  local pattern=$2
  echo "Searching for '$name' processes with command line matching '$pattern'..."
  powershell.exe -Command "
    \$processes = Get-CimInstance Win32_Process -Filter \"name = '$name'\" | Where-Object { \$_.CommandLine -match '$pattern' };
    if (\$processes) {
      \$processes | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize;
    } else {
      Write-Host \"No matching '$name' processes found\";
    }
  "
}

# Kill all processes with a specific name
killall() {
  local name=$1
  echo "Finding and killing all '$name' processes..."
  powershell.exe -Command "
    \$processes = Get-CimInstance Win32_Process -Filter \"name = '$name'\";
    if (\$processes) {
      foreach (\$process in \$processes) {
        Stop-Process -Id \$process.ProcessId -Force;
        Write-Host \"Killed process \$(\$process.ProcessId)\";
      }
    } else {
      Write-Host \"No '$name' processes found\";
    }
  "
}

# Kill processes with a specific name and command line pattern
kill() {
  local name=$1
  local pattern=$2
  echo "Finding and killing '$name' processes with command line matching '$pattern'..."
  powershell.exe -Command "
    \$processes = Get-CimInstance Win32_Process -Filter \"name = '$name'\" | Where-Object { \$_.CommandLine -match '$pattern' };
    if (\$processes) {
      foreach (\$process in \$processes) {
        Stop-Process -Id \$process.ProcessId -Force;
        Write-Host \"Killed process \$(\$process.ProcessId)\";
      }
    } else {
      Write-Host \"No matching '$name' processes found\";
    }
  "
}

# Check if being run directly or sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If run directly (not sourced), provide command line interface
  case "$1" in
    list)
      if [ -z "$2" ]; then
        echo "Usage: $0 list PROCESS_NAME"
        exit 1
      fi
      list "$2"
      ;;
    search)
      if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: $0 search PROCESS_NAME COMMANDLINE_PATTERN"
        exit 1
      fi
      search "$2" "$3"
      ;;
    killall)
      if [ -z "$2" ]; then
        echo "Usage: $0 killall PROCESS_NAME"
        exit 1
      fi
      killall "$2"
      ;;
    kill)
      if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: $0 kill PROCESS_NAME COMMANDLINE_PATTERN"
        exit 1
      fi
      kill "$2" "$3"
      ;;
    *)
      echo "Usage: $0 {list PROCESS_NAME|search PROCESS_NAME COMMANDLINE_PATTERN|killall PROCESS_NAME|kill PROCESS_NAME COMMANDLINE_PATTERN}"
      exit 1
      ;;
  esac
fi
