#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  docker-deploy.sh — Deploy adapter for Docker / Docker Compose          ║
# ║                                                                          ║
# ║  Sourced by shipwright init --deploy to generate platform-specific commands.   ║
# ║  Exports: staging_cmd, production_cmd, rollback_cmd, detect_platform    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

adapter_name="docker"

detect_platform() {
    # Docker: look for Dockerfile or docker-compose.yml/yaml
    [[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]
}

get_staging_cmd() {
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        echo "docker compose build && docker compose up -d"
    else
        echo "docker build -t \$(basename \$(pwd)):staging . && docker run -d --name \$(basename \$(pwd))-staging \$(basename \$(pwd)):staging"
    fi
}

get_production_cmd() {
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        echo "docker compose -f docker-compose.yml -f docker-compose.prod.yml build && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d"
    else
        echo "docker build -t \$(basename \$(pwd)):latest . && docker run -d --name \$(basename \$(pwd)) \$(basename \$(pwd)):latest"
    fi
}

get_rollback_cmd() {
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        echo "docker compose down && docker compose up -d --force-recreate"
    else
        echo "docker stop \$(basename \$(pwd)) && docker rm \$(basename \$(pwd)) && docker run -d --name \$(basename \$(pwd)) \$(basename \$(pwd)):previous"
    fi
}

get_health_url() {
    echo "http://localhost:8767/health"
}

get_smoke_cmd() {
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        echo "docker compose ps --format json | jq -e 'all(.State == \"running\")'"
    else
        echo "docker inspect --format='{{.State.Running}}' \$(basename \$(pwd)) | grep >/dev/null true"
    fi
}
