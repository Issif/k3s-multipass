# What it is

This script will:
* create a 2 nodes `k3s` cluster with `multipass`
* install `falco`, `falcosidekick`, `falcosidekick-ui` with `helm`
* install `kubeless`
* install `delete-pod` function (triggered by a running in a pod in `default` namespace)
* enable `audit-logs`
* set up the whole chain of components `audit-logs` > `falco` > `falcosidekick` > `falcosidekick-ui` & `kubeless`
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