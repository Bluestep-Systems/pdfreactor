home=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.home = //p')
[ "$home" = "$EXPECTED_JAVA_HOME" ] || { echo "jvm-security: java.home is '$home', the chart expects '$EXPECTED_JAVA_HOME'" >&2; exit 1; }
out=/merged; kt="$home/bin/keytool"
# A fingerprint list: comments and blank lines dropped, ':' and whitespace stripped, uppercased.
fps() { sed 's/#.*//' "$1" | tr -d ': \t\r' | tr 'a-f' 'A-F' | grep -v '^$' || true; }
# take <mount> <dest> <required|optional>: copies the three keys out of one revision of a ConfigMap
# mount. The kubelet swaps the ..data symlink on update and then deletes the old revision, so a copy
# counts only if ..data still points at the revision it was read from; otherwise read again.
take() {
  n=0
  while :; do
    rev=$(readlink -f "$1/..data" 2>/dev/null) && [ -d "$rev" ] || rev="$1"
    rm -rf "$2"; mkdir -p "$2"; missing=
    for k in blocked.certs.extra distrusted.anchors java.security; do
      cp "$rev/$k" "$2/$k" 2>/dev/null || { : > "$2/$k"; missing="$missing $k"; }
    done
    [ "$rev" = "$1" ] && break
    [ "$(readlink -f "$1/..data" 2>/dev/null)" = "$rev" ] && [ -d "$rev" ] && break
    n=$((n + 1)); [ $n -lt 5 ] || { echo "jvm-security: $1 kept changing while it was read" >&2; exit 1; }
  done
  [ -z "$missing" ] || [ "$3" != required ] || { echo "jvm-security: $1 is missing:$missing" >&2; exit 1; }
  for k in blocked.certs.extra distrusted.anchors java.security; do
    # grep reads a file with NUL bytes (e.g. UTF-16) as binary and prints nothing, and Java reads a UTF-8
    # BOM as part of the first property's name: refuse both rather than let a setting silently do nothing.
    [ "$(tr -d '\000' < "$2/$k" | wc -c)" -eq "$(wc -c < "$2/$k")" ] \
      || { echo "jvm-security: $1/$k contains NUL bytes (UTF-16?); save it as UTF-8 or ASCII" >&2; exit 1; }
    [ "$(head -c 3 "$2/$k" | od -An -tx1 | tr -d ' \n')" != efbbbf ] \
      || { echo "jvm-security: $1/$k starts with a UTF-8 byte-order mark; save it without one" >&2; exit 1; }
  done
}
# The chart's ConfigMap, then the operator's optional -local one. Helm never renders -local, so an
# emergency edit made there survives deploys. Fingerprints are the union; its java.security lines come last and win.
take /etc/bluestep/jvm-security-src "$out/.src/chart" required
take /etc/bluestep/jvm-security-local "$out/.src/local" optional
src="$out/.src"
for k in blocked.certs.extra distrusted.anchors java.security; do
  # Two newlines: a chart value ending in a '\' continuation must not swallow the first local line.
  { cat "$src/chart/$k"; printf '\n\n'; cat "$src/local/$k"; } > "$src/$k"
done
# Refuse what keytool -showinfo -tls can't vouch for. JAR-signing constraints load only when a signed JAR
# does; an include names a file the app container can't see. A key spelled with a '\' (an escape or a
# continuation) could hide either from this check, and no key we set needs one. This reads every line's
# first token as a key, continuation lines too: stricter than Java, never looser.
bad=$(awk '{ sub(/^[ \t\f]+/, "") } /^$/ || /^[#!]/ { next }
  { k = $0; sub(/[=: \t\f].*$/, "", k); if (k ~ /\\/ || k ~ /^jdk\.jar\./ || k == "include") print k }' "$src/java.security")
[ -z "$bad" ] || { echo "jvm-security: java.security sets keys this check cannot validate (jdk.jar.*, include, or a '\\' in a key); refused: $(echo $bad)" >&2; exit 1; }
for k in blocked.certs.extra distrusted.anchors; do
  bad=$(fps "$src/$k" | grep -vE '^[0-9A-F]{64}$' || true)
  [ -z "$bad" ] || { echo "jvm-security: not a SHA-256 fingerprint in $k: $bad" >&2; exit 1; }
done
# blocked.certs: the JDK's own list, then ours.
{ cat "$home/lib/security/blocked.certs"; echo; fps "$src/blocked.certs.extra"; } > "$out/blocked.certs"
# cacerts: the image's own trust store, minus every anchor whose SHA-256 is listed.
cp -L "$home/lib/security/cacerts" "$out/cacerts"; chmod u+w "$out/cacerts"
fps "$src/distrusted.anchors" > "$out/.distrust"
# Writes "<SHA-256>\t<alias>" per entry to $out/.anchors; stops the pod if keytool cannot read the store.
anchors() {
  "$kt" -list -v -keystore "$out/cacerts" -storepass changeit > "$out/.list" 2>&1 \
    || { tail -n 5 "$out/.list" >&2; echo "jvm-security: keytool could not read $out/cacerts" >&2; exit 1; }
  awk '/^Alias name:/ {a = substr($0, 13)} /SHA256:/ {f = $2; gsub(/:/, "", f); print f "\t" a}' "$out/.list" > "$out/.anchors"
}
anchors
# An image store with no entries at all means keytool read the wrong thing; an emptied one after pruning is fine.
[ -s "$out/.anchors" ] || { echo "jvm-security: keytool listed no entries in $out/cacerts" >&2; exit 1; }
while IFS="$(printf '\t')" read -r f a; do
  grep -qxF "$f" "$out/.distrust" || continue
  "$kt" -delete -alias "$a" -keystore "$out/cacerts" -storepass changeit && echo "jvm-security: distrusted $a"
done < "$out/.anchors"
anchors
# (busybox grep -f with an empty pattern file matches every line, hence the -s test)
left=$( [ ! -s "$out/.distrust" ] || cut -f1 "$out/.anchors" | grep -xF -f "$out/.distrust" || true)
rm -f "$out/.distrust" "$out/.list" "$out/.anchors"
[ -z "$left" ] || { echo "jvm-security: still trusted after pruning: $left" >&2; exit 1; }
# java.security: the app reads this validated copy, never the live ConfigMap.
f="$out/java.security"; cp "$src/java.security" "$f"; rm -rf "$out/.src"
out="$("$kt" -J-Djava.security.debug=properties -J-Djava.security.properties="$f" -showinfo -tls 2>&1)" \
  && ! printf '%s' "$out" | grep -qi -e 'unable to load security properties' -e 'Exception in thread' \
  || { printf '%s\n' "$out" | grep -i -A3 -e 'unable to load' -e exception -e error | head -n 20 >&2; echo "jvm-security: refused $f" >&2; exit 1; }
