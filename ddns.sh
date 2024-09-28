#!/usr/bin/env bash

SCRIPT_DIR=$(cd $(dirname $0); pwd)
set -a; source "${SCRIPT_DIR}/.env"; set +a

TOKEN_PATH="${SCRIPT_DIR}/ddns-token.json"
if [ -f "${TOKEN_PATH}" ]; then
  TOKEN=`jq -r '.token' "${TOKEN_PATH}"`
  EXPIRES_NUM=`jq -r '.expires_num' "${TOKEN_PATH}"`
fi
CURRENT_NUM=`date -u '+%Y%m%d%H%M%S'`

domain_uuid() {
  RESPONSE=`curl -s -w '\n\n%{http_code}' -X GET \
    -H 'Accept: application/json' \
    -H 'X-Auth-Token: '"$1" \
    'https://dns-service.c3j1.conoha.io/v1/domains'`
  JSON=`echo "${RESPONSE}" | sed '/^$/,$d'`
  CODE=`echo "${RESPONSE}" | tail -n 1`
  UUID=`echo "${JSON}" | jq -r '.domains[] | select(.name == "'"${DOMAIN}."'") | .uuid'`
  echo "${UUID}"
  if [ "${CODE}" != "200" ]; then
    return 1
  else
    return 0
  fi
}
record_uuid() {
  RESPONSE=`curl -s -w '\n\n%{http_code}' -X GET \
    -H 'Accept: application/json' \
    -H 'X-Auth-Token: '"$1" \
    'https://dns-service.c3j1.conoha.io/v1/domains/'"$2"'/records'`
  JSON=`echo "${RESPONSE}" | sed '/^$/,$d'`
  CODE=`echo "${RESPONSE}" | tail -n 1`
  UUID=`echo "${JSON}" | jq -r '.records[] | select(.name == "'"${HOST}.${DOMAIN}."'") | .uuid'`
  echo "${UUID}"
  if [ "${CODE}" != "200" ]; then
    return 1
  else
    return 0
  fi
}
update_record() {
  RESPONSE=`curl -s -w '\n\n%{http_code}' -X PUT \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -H 'X-Auth-Token: '"$1" \
    -d '{"data": "'"$4"'"}' \
    'https://dns-service.c3j1.conoha.io/v1/domains/'"$2"'/records/'"$3"`
  JSON=`echo "${RESPONSE}" | sed '/^$/,$d'`
  CODE=`echo "${RESPONSE}" | tail -n 1`
  NAME=`echo "${JSON}" | jq -r '.name'`
  echo $NAME
  if [ "${CODE}" != "200" ]; then
    return 1
  else
    return 0
  fi
}

TMP=`curl -s --retry 5 -w '\n%{http_code}' 'https://checkip.amazonaws.com'`
NEWIP=`echo "${TMP}" | sed '/^$/,$d'`
CODE=`echo "${TMP}" | tail -n 1`
if [ "${CODE}" != "200" ]; then
  CODETXT=",${CODE}"
fi
OLDIP=`nslookup "${HOST}.${DOMAIN}" 'a.conoha-dns.com' | grep Address | egrep -o "[0-9]+(\.[0-9]+){3}$"`
if [ -z "${OLDIP}" ]; then
  COUNT=0
  while [ ${COUNT} -ne 5 ]
  do
    COUNT=`expr ${COUNT} + 1`
    sleep 5
    OLDIP=`nslookup "${HOST}.${DOMAIN}" 'a.conoha-dns.com' | grep Address | egrep -o "[0-9]+(\.[0-9]+){3}$"`
    if [ -n "${OLDIP}" ]; then
      break
    fi
  done
  OLDIP_RETRY="(${COUNT})"
fi
CONTENT="NewIP: ${NEWIP}${NEWIP_RETRY}${CODETXT}\nOldIP: ${OLDIP}${OLDIP_RETRY}"
if [ -n "${EXPIRES_NUM}" ]; then
  EXPIRES_UNIXTIME=`date -d "${EXPIRES_NUM:0:8} ${EXPIRES_NUM:8:2}:${EXPIRES_NUM:10:2}:${EXPIRES_NUM:12:2}" '+%s'`
  CURRENT_UNIXTIME=`date -d "${CURRENT_NUM:0:8} ${CURRENT_NUM:8:2}:${CURRENT_NUM:10:2}:${CURRENT_NUM:12:2}" '+%s'`
  LIMIT_HOUR="$(($((EXPIRES_UNIXTIME-CURRENT_UNIXTIME))/60/60))"
  if [ "${LIMIT_HOUR}" -lt "-24" ]; then
    CONTENT="${CONTENT}\nToken: $((LIMIT_HOUR/24))d"
  else
    CONTENT="${CONTENT}\nToken: ${LIMIT_HOUR}h"
  fi
fi
if [ -z "${NEWIP}" ] || [ -z "${OLDIP}" ] || [ "${NEWIP}" = "${OLDIP}" ]; then
  SUBJECT="[${HOST}]IP変更なし"
  CONTENT="${CONTENT}\nDDNS: No Change."
else
  SUBJECT="[${HOST}]IP変更されました"
  if [ -z "${EXPIRES_NUM}" ] || [ "${EXPIRES_NUM}" -lt "$((${CURRENT_NUM} + 100))" ]; then
    TOKEN_TMP=`curl -s -i -X POST \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -d '{"auth": {"identity": {"methods": ["password"],"password": {"user": {"id": "'"${API_USERID}"'","password": "'"${API_PASSWORD}"'"}}},"scope": {"project": {"id": "'"${API_PROJECTID}"'"}}}}' \
      'https://identity.c3j1.conoha.io/v3/auth/tokens'`
    TOKEN=`echo "${TOKEN_TMP}" | grep x-subject-token | awk '{print $2}' | sed 's/\r//g'`
    JSON=`echo "${TOKEN_TMP}" | sed '1,/^\s*$/d'`
    EXPIRES_AT=`echo "${JSON}" | jq -r '.token.expires_at'`
    EXPIRES_NUM=`date -u -d "${EXPIRES_AT}" '+%Y%m%d%H%M%S'`
    jq -n '.token = "'"${TOKEN}"'"' | jq '.expires_num = "'"${EXPIRES_NUM}"'"' > "${TOKEN_PATH}"
    EXPIRES_UNIXTIME=`date -d "${EXPIRES_NUM:0:8} ${EXPIRES_NUM:8:2}:${EXPIRES_NUM:10:2}:${EXPIRES_NUM:12:2}" '+%s'`
    CURRENT_UNIXTIME=`date -d "${CURRENT_NUM:0:8} ${CURRENT_NUM:8:2}:${CURRENT_NUM:10:2}:${CURRENT_NUM:12:2}" '+%s'`
    LIMIT_HOUR="$(($((EXPIRES_UNIXTIME-CURRENT_UNIXTIME))/60/60))"
    CONTENT="${CONTENT}\nNewToken: ${LIMIT_HOUR}h"
  fi
  DOMAIN_UUID=`domain_uuid "${TOKEN}"`
  if [ $? -eq 0 ]; then
    RECORD_UUID=`record_uuid "${TOKEN}" "${DOMAIN_UUID}"`
    if [ $? -eq 0 ]; then
      UPDATE_DOMAIN=`update_record "${TOKEN}" "${DOMAIN_UUID}" "${RECORD_UUID}" "${NEWIP}"`
    fi
  fi
  if [ -n "${UPDATE_DOMAIN}" ]; then
    CONTENT="${CONTENT}\nDDNS: Successful."
  else
    CONTENT="${CONTENT}\nDDNS: Failed."
  fi
fi
#TODO NEWIP_RETRY&OLDIP_RETRY DELETE
if [ "${NEWIP}" != "${OLDIP}" ] || [ "${1}" = "boot" ] || [ -n "${NEWIP_RETRY}" ] || [ -n "${OLDIP_RETRY}" ]; then
  curl --request POST \
    --url 'https://api.sendgrid.com/v3/mail/send' \
    --header 'Authorization: Bearer '"${MAIL_API_KEY}" \
    --header 'Content-Type: application/json' \
    --data '{"personalizations": [{"to": [{"email": "'"${MAIL_TO}"'"}]}],"from": {"email": "'"${MAIL_FROM}"'"},"subject": "'"${SUBJECT}"'","content": [{"type": "text/plain","value": "'"${CONTENT}"'"}]}'
fi
