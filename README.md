# What it is

This script will:
* create a 2 nodes `k3s` cluster with `multipass`
* install `falco`, `falcosidekick`, `falcosidekick-ui` with `helm`
* enable `audit-logs`

## Prerequisities

* `multipass`
* `helm`
* `kubectl`
* `jq`

## Usage

```shell
./bootstrap.sh
```

## Author

Thomas Labarussias [[@Issif](https://github.com/Issif)]