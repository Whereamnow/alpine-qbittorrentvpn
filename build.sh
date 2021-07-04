#!/bin/bash
nice docker buildx build --no-cache --push --platform linux/arm/v7,linux/arm64/v8,linux/amd64,linux/arm/v8 -t trigus42/qbittorrentvpn -t trigus42/qbittorrentvpn:alpine-$(date +'%Y%m%d') .