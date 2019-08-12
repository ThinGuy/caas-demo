
(
trap 'printf "%s\n" smam cnorm rmcup|tput -S -;trap - INT TERM EXIT;' INT TERM EXIT
printf '%s\n' rmam civis smcup clear|tput -x -S -;
while [[ ! -f ~/caas-demo/log/demo.log ]];do tput civis && printf '\rWaiting for log\e[K';done;
less -sSQ -Pw"Processing log" +RF ~/caas-demo/log/demo.log;
printf "%s\n" smam rmcup cnorm|tput -S -;
trap - INT TERM EXIT;
) 

(
trap 'printf "%s\n" smam cnorm rmcup|tput -S -;trap - INT TERM EXIT;' INT TERM EXIT
printf '%s\n' rmam civis smcup clear|tput -x -S -;
while ! (juju 2>/dev/null controllers --refresh|grep -iqo aws);do tput civis && printf '\rWaiting for controllers\e[K';done;
while true;do tput civis && juju 2>/dev/null controllers --refresh|sed '/^$/d';sleep 1;tput cup 0 0;done;
printf "%s\n" smam rmcup cnorm|tput -S -;
trap - INT TERM EXIT;
) 


(
export CDK_MODEL=cdk-aws
trap 'printf "%s\n" smam cnorm rmcup|tput -S -;trap - INT TERM EXIT;' INT TERM EXIT
printf '%s\n' rmam civis smcup clear|tput -x -S -;
while ! (juju 2>/dev/null models|grep -iqo cdk);do tput civis && printf '\rWaiting for machines\e[K';done;
tput clear;
while true;do
	tput cup 0 0;
	(printf "Unit|Workload|Agent|Machine|Message\e[K\n";juju status -m ${CDK_MODEL} --format json|jq -r '.applications|keys[] as $k|.[$k]|select(.units != null)|.units|to_entries[]|"\(.key)|\(.value."workload-status".current)|\(.value."juju-status".current)|\(.value.machine)|\(.value."juju-status".message)","  \(select(.value.subordinates != null)|.value.subordinates|to_entries[]|.key)|\(.value."workload-status".current)|\(.value."juju-status".current)|\(.value.machine)|\(.value."juju-status".message)"'|sed 's/null//g')|column -nexts'|'|sed -E -e 's/unknown/active'$(printf "\e[33m\u1d58\e[0m")'/g' -e '1s/^.*$/'$(printf "\e[1m&\e[0m")'/' -e 's/active|idle|executing/'$(printf "\e[32m&\e[0m")'/g' -e 's/blocked|maintenance/'$(printf "\e[33m&\e[0m")'/g' -e 's/error/'$(printf "\e[31m&\e[0m")'/g'
sleep 1;
done
printf "%s\n" smam rmcup cnorm|tput -S -;
trap - INT TERM EXIT;
)


(
trap 'printf "%s\n" smam cnorm rmcup|tput -S -;trap - INT TERM EXIT;' INT TERM EXIT
printf '%s\n' rmam civis smcup clear|tput -x -S -;
while ! (juju 2>/dev/null models|grep -iqo cdk);do tput civis && printf '\rwaiting for models\e[K';sleep 1;done;
watch -tcn1 "juju status -m cdk-aws --color |awk '/Unit/{flag=1;next}/^$/{flag=0}flag {gsub(/^  /,\"--\");gsub(/\|/,\"\");print \$1\"|\"\$2\"|\"\$3\"|'$(printf "\e[0m")'\"substr(\$0,"Message",length(\$0))}'|sed 's/^--/  /g;s/$/'$(printf "\e[0m")'&/g'|column -nexts'|'"
printf "%s\n" smam rmcup cnorm|tput -S -;
trap - INT TERM EXIT;
)


