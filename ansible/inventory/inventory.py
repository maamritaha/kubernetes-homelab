#!/usr/bin/env python3

import json
import sys
from pathlib import Path

import yaml


def load_yaml(file_path):
    with open(file_path, "r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def build_inventory(cluster_config):
    inventory = {
        "_meta": {
            "hostvars": {}
        },
        "all": {
            "vars": {
                "cluster_environment": cluster_config["environment"]
            }
        },
        "control_plane": {
            "hosts": []
        },
        "workers": {
            "hosts": []
        }
    }

    for server in cluster_config["servers"]:
        name = server["name"]
        ip_address = server["ip_address"]
        role = server["role"]

        inventory["_meta"]["hostvars"][name] = {
            "ansible_host": ip_address
        }

        if role == "control_plane":
            inventory["control_plane"]["hosts"].append(name)

        elif role == "worker":
            inventory["workers"]["hosts"].append(name)

        else:
            raise ValueError(
                f"Unsupported server role '{role}' for server '{name}'"
            )

    return inventory


def main():
    if len(sys.argv) != 2:
        print(
            f"Usage: {sys.argv[0]} <environment-config.yaml>",
            file=sys.stderr,
        )
        sys.exit(1)

    environment_config_path = Path(sys.argv[1]).resolve()
    environment_config = load_yaml(environment_config_path)

    cluster_config_path = (
        environment_config_path.parent
        / environment_config["cluster_config"]
    ).resolve()

    cluster_config = load_yaml(cluster_config_path)
    inventory = build_inventory(cluster_config)

    print(json.dumps(inventory, indent=2))


if __name__ == "__main__":
    main()
