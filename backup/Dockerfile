FROM alpine:3.6
LABEL maintainer "Flavien Hardy <flav.hardy@gmail.com>"

ENV HEKETI_DB /var/lib/heketi/heketi.db
WORKDIR /backupdb

COPY ./cron.sh /

ENTRYPOINT [""]
CMD ["/cron.sh"]
