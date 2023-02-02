FROM eclipse-temurin:8-jre-alpine
WORKDIR /minecraft
ADD http://downloads.gtnewhorizons.com/ServerPacks/GT_New_Horizons_2.2.3_SERVER.zip /gtnh.zip
#COPY GT_New_Horizons_2.2.0.0_SERVER.zip /gtnh.zip
RUN unzip -d /minecraft /gtnh.zip && rm /gtnh.zip
RUN addgroup -S app && adduser -S app -G app && chown -R app:app /minecraft
USER app
CMD [ "sh", "startserver.sh" ]
