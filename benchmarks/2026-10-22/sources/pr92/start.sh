#!/usr/bin/env bash
set -euo pipefail

cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null
java -Xms900m -Xmx1800m -Xmn850m \
      -XX:+AlwaysPreTouch \
      -XX:+UseTransparentHugePages \
      -XX:+UseSerialGC -XX:ActiveProcessorCount=1 \
      -XX:MaxDirectMemorySize=256m \
      -XX:MetaspaceSize=96m -XX:MaxMetaspaceSize=128m \
      -XX:-UsePerfData \
      -jar tds-challenge-vertx-app.jar
