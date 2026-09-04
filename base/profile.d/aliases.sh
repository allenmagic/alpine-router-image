# 常用别名（busybox ash 支持 alias）
# 注意：仅交互 shell 生效——ssh host 'll' 这类非交互命令不会加载
# /etc/profile，属 ash 的固有语义（别名为解析期展开，非 PATH 命令）
alias ll='ls -lhr'
alias lla='ls -alhr'
