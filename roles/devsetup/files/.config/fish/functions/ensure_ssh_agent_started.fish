function __ssh_agent_is_started -d "Check if an ssh agent is already running."
  if begin; test -f $SSH_ENV; and test -z "$SSH_AGENT_PID"; end
    source $SSH_ENV > /dev/null
  end

  if test -z "$SSH_AGENT_PID"
    return 1
  end

  ps -ef | grep $SSH_AGENT_PID | grep -v grep | grep -q ssh-agent
  #pgrep ssh-agent
  return $status
end

function __start_ssh_agent -d "Start a new ssh agent."
  ssh-agent -c | sed 's/^echo/#echo/' > $SSH_ENV
  chmod 600 $SSH_ENV
  source $SSH_ENV > /dev/null
  true  # suppress errors from setenv, i.e. set -gx
end

function ensure_ssh_agent_started
  if test -z "$SSH_ENV"
    set -xg SSH_ENV $HOME/.ssh/environment
  end

  if not __ssh_agent_is_started
    __start_ssh_agent
  end
end
