FROM rabbitmq:3-management

# Spring STOMP Broker Relay 가 접속하려면 STOMP 플러그인이 필요하다.
# --offline: 브로커가 실행 중이 아니어도 이미지 빌드 시점에 플러그인을 켠다.
RUN rabbitmq-plugins enable --offline rabbitmq_stomp
