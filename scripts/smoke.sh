#!/usr/bin/env bash
# End-to-end checks against the running stack (production or dev).
#   API_KEY=<key created in the LocalAI UI> scripts/smoke.sh
#   SCHEME=http ... for the plain-HTTP dev mode (dev/compose.dev.yml).
#   DECISION_MODELS="..." to choose which decision models to test.
#   CURL_CA_BUNDLE=/path/ca.crt if Apache's certificate comes from an internal CA.
# Optional: REVOKED_KEY=<a paused/revoked key> to check it is rejected.
set -uo pipefail
cd "$(dirname "$0")/.."
DOMAIN="${DOMAIN:-$(grep -E '^DOMAIN=' .env | cut -d= -f2)}"
SCHEME="${SCHEME:-https}"
BASE="${SCHEME}://ai.${DOMAIN}"
CURL=(curl -sS -o /tmp/smoke-body.$$ -w '%{http_code}')
EMBED_MODEL="${EMBED_MODEL:-bge-m3}"
RERANK_MODEL="${RERANK_MODEL:-bge-reranker-v2-m3}"
DECISION_MODELS="${DECISION_MODELS:-laya-llama-cpp kev-4b-llama-cpp}"
fail=0

check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; head -c 400 /tmp/smoke-body.$$; echo; fail=1; fi
}

check "readyz"                    200 "$("${CURL[@]}" "$BASE/readyz")"
check "embeddings without key"    401 "$("${CURL[@]}" -X POST "$BASE/v1/embeddings" -H 'Content-Type: application/json' -d '{"model":"x","input":"x"}')"
check "embeddings with bad key"   401 "$("${CURL[@]}" -X POST "$BASE/v1/embeddings" -H 'Authorization: Bearer nope' -H 'Content-Type: application/json' -d '{"model":"x","input":"x"}')"
check "chat is blocked"           403 "$("${CURL[@]}" -X POST "$BASE/v1/chat/completions" -H "Authorization: Bearer ${API_KEY:-x}" -H 'Content-Type: application/json' -d '{}')"
check "completions is blocked"    403 "$("${CURL[@]}" -X POST "$BASE/v1/completions" -H "Authorization: Bearer ${API_KEY:-x}" -d '{}')"

if [[ -n "${REVOKED_KEY:-}" ]]; then
  check "revoked key"             401 "$("${CURL[@]}" -X POST "$BASE/v1/embeddings" -H "Authorization: Bearer $REVOKED_KEY" -H 'Content-Type: application/json' -d '{"model":"x","input":"x"}')"
fi

if [[ -z "${API_KEY:-}" ]]; then
  echo "API_KEY not set: skipping authenticated checks (log in at $BASE and create a key)."
  exit $fail
fi
AUTH=(-H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json')

check "embeddings"  200 "$("${CURL[@]}" --max-time 900 -X POST "$BASE/v1/embeddings" "${AUTH[@]}" \
  -d "{\"model\":\"$EMBED_MODEL\",\"input\":[\"hello world\",\"hallo welt\"]}")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("     dims:", len(d["data"][0]["embedding"]), "vectors:", len(d["data"]))' /tmp/smoke-body.$$ 2>/dev/null

check "rerank"      200 "$("${CURL[@]}" --max-time 900 -X POST "$BASE/v1/rerank" "${AUTH[@]}" \
  -d "{\"model\":\"$RERANK_MODEL\",\"query\":\"refund for a broken order\",\"documents\":[\"Shipping times to Europe\",\"How to request a refund for damaged goods\",\"Changing your password\"],\"top_n\":2}")"
head -c 300 /tmp/smoke-body.$$; echo

for m in $DECISION_MODELS; do
  check "decisions $m" 200 "$("${CURL[@]}" --max-time 900 -X POST "$BASE/v1/systemone" "${AUTH[@]}" -d @- <<JSON
{"model":"$m","state":"My order arrived broken and I want my money back. This is the second time.",
 "questions":{
  "team":{"type":"choice","instructions":"Which team should handle this ticket?",
          "criteria":{"billing":"Payments, invoices and refunds","shipping":"Delivery and damaged goods","product":"How the product works"}},
  "refund_requested":{"type":"noul","instructions":"The customer explicitly asks for a refund"},
  "urgency":{"type":"score","instructions":"How urgent is this ticket?","criteria":["not urgent","somewhat urgent","urgent","critical"]}}}
JSON
)"
  head -c 400 /tmp/smoke-body.$$; echo
done

check "user key cannot install models" 403 "$("${CURL[@]}" -X POST "$BASE/models/apply" "${AUTH[@]}" -d '{"id":"localai@laya-llama-cpp"}')"

rm -f /tmp/smoke-body.$$
exit $fail
