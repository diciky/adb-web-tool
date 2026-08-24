FROM gradle:8.9-jdk17

USER root
RUN apt-get update && apt-get install -y unzip curl && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

RUN mkdir -p $ANDROID_HOME/cmdline-tools \
  && cd $ANDROID_HOME/cmdline-tools \
  && curl -sL -o cmd.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  && unzip -q cmd.zip \
  && mv cmdline-tools latest \
  && rm cmd.zip

RUN yes | sdkmanager --sdk_root=$ANDROID_HOME --licenses
RUN sdkmanager --sdk_root=$ANDROID_HOME "platform-tools" "platforms;android-33" "build-tools;33.0.2"
RUN chmod -R a+rx $ANDROID_HOME

WORKDIR /app
COPY . /app
RUN chown -R gradle:gradle /app
USER gradle
RUN gradle assembleDebug --no-daemon

CMD ["sh", "-c", "cp -r /app/app/build/outputs/apk /apkout && tail -f /dev/null"]
