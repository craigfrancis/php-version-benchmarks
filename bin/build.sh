#!/usr/bin/env bash
set -e

if [[ "$1" == "$INFRA_ENVIRONMENT" && "$INFRA_ENVIRONMENT" != "local" && "$INFRA_PROVISIONER" == "host" ]]; then
    $PROJECT_ROOT/build/script/php_deps.sh
fi

for php_config in $PROJECT_ROOT/config/php/*.ini; do
    source "$php_config"
    export $(cut -d= -f1 $php_config)
    export PHP_SOURCE_PATH="$PROJECT_ROOT/tmp/$PHP_ID"
    if [ -z "$PHP_BASE_ID" ]; then
        export PHP_BASE_SOURCE_PATH=""
    else
        export PHP_BASE_SOURCE_PATH="$PROJECT_ROOT/tmp/$PHP_BASE_ID"
    fi

    if [[ "$1" == "local" || "$INFRA_PROVISIONER" == "host" ]]; then
        $PROJECT_ROOT/build/script/php_source.sh "$1"
    fi

    if [[ "$1" == "local" && "$INFRA_PROVISIONER" == "docker" ]]; then
        tag="$INFRA_DOCKER_REPOSITORY:$PHP_ID-latest"

        cp "$PROJECT_ROOT/.dockerignore" "$PHP_SOURCE_PATH/.dockerignore"
        docker build -f "$PROJECT_ROOT/Dockerfile" -t "$tag" "$PHP_SOURCE_PATH"

        if [[ "$INFRA_ENVIRONMENT" == "aws" ]]; then
            aws ecr-public get-login-password --region "us-east-1" | docker login --username AWS --password-stdin "$INFRA_DOCKER_REGISTRY"
            docker tag "$tag" "$INFRA_DOCKER_REGISTRY/$tag"
            docker push "$INFRA_DOCKER_REGISTRY/$tag"
        fi
    fi

    if [[ "$1" == "$INFRA_ENVIRONMENT" && "$INFRA_PROVISIONER" == "host" ]]; then
        $PROJECT_ROOT/build/script/php_compile.sh
    fi
done
