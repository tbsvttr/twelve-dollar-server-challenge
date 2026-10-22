FROM ubuntu:24.04
COPY install.sh /tmp/install.sh
RUN bash /tmp/install.sh
USER ubuntu
COPY --chown=ubuntu:ubuntu . /home/ubuntu/app
RUN bash /home/ubuntu/app/build.sh
CMD ["bash", "/home/ubuntu/app/start.sh"]
