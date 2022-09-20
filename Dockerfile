
FROM lyrth/luvit

## config
EXPOSE 8080 ${PORT}

ARG USERNAME=luaserver
ARG GROUPNAME=web
ARG GID=6969


## add non-root user
RUN addgroup -g $GID $GROUPNAME  &&\
    adduser -D -H -g "" $USERNAME  &&\
    adduser $USERNAME $GROUPNAME

## fetch dependencies
WORKDIR /server
COPY package.lua .
RUN lit install || true  &&\
    test -d deps  &&\
    rm -rf /root/.litdb.git/

## copy files and set perms
COPY . .
RUN chown -R $USERNAME:$GROUPNAME /server  &&\
    chmod -R ug+rw /server
USER $USERNAME

## entrypoint
CMD ["luvit", "main.lua"]
