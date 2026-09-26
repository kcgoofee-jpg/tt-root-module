# 备份分层保留：手机上的模块和电脑上的 mac/pull-backups.sh 共用。
# 输入：备份文件名，一行一个（前缀-YYYYmmdd-HHMMSS.tar.gz，旧版本的 HHMM 也认）。
# 前缀不同（tt-default-user / sillydroid / termux-st）的分开算：每个酒馆各自保留。
# 变量：today=YYYYmmdd，days=按天留几天，weeks=按周留几周，months=按月留几个月。
# 输出：每个文件一行「keep 层级 文件名」或「drop - 文件名」。层级：
#   new   最新的一份（永远留着）
#   2d    最近 2 天内的，全留（每 6 小时一份的那些）
#   day   最近 days 天，每天留最新的一份
#   week  最近 weeks 周，每周留最新的一份
#   month 最近 months 个月，每月留最新的一份
# 更旧的，或者同一天 / 周 / 月里已经有更新的一份了，就 drop。
#   pre   恢复前自动存的那份（-prerestore）：这里不管，永远 keep（另有「只留 3 份」的规则）
# 防呆：系统时间跳到了未来（比最新的备份晚一年多），这次什么都不删。

function dn(y, m, d) {            # 公历日期 → 连续的天数（只用来算差值）
    if (m <= 2) { y--; m += 12 }
    return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d
}
function stamp(name,   s) {       # 文件名里的 YYYYmmdd-HHMM[SS]，拿来排序
    s = name; sub(/\.tar\.gz$/, "", s)
    if (match(s, /-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]+$/)) s = substr(s, RSTART + 1)
    return s
}
function prefix(name,   s) {      # 文件名里时间前面的部分
    s = name
    if (match(s, /-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-/)) s = substr(s, 1, RSTART - 1)
    return s
}
/-prerestore\.tar\.gz$/ { pre[++np] = $0; next }
{
    # 不用 {8} 这种写法：有的 awk（老的 busybox / mawk）不认
    if ($0 !~ /^(tt-default-user|sillydroid|termux-st)-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]([0-9][0-9])?\.tar\.gz$/) next
    n++; name[n] = $0; key[n] = stamp($0)
}
END {
    # 新的在前（按文件名里的时间排，插入排序：份数不多）
    for (i = 2; i <= n; i++) {
        t = name[i]; k = key[i]
        for (j = i - 1; j >= 1 && key[j] < k; j--) { name[j + 1] = name[j]; key[j + 1] = key[j] }
        name[j + 1] = t; key[j + 1] = k
    }
    ty = substr(today, 1, 4) + 0; tm = substr(today, 5, 2) + 0; td = substr(today, 7, 2) + 0
    now = dn(ty, tm, td)
    for (i = 1; i <= np; i++) print "keep pre " pre[i]
    if (n) {
        y = substr(key[1], 1, 4) + 0; m = substr(key[1], 5, 2) + 0; d = substr(key[1], 7, 2) + 0
        if (now - dn(y, m, d) > 400) { for (i = 1; i <= n; i++) print "keep new " name[i]; exit }
    }
    # 下面的 seen 和「最新一份」都按前缀分开
    for (i = 1; i <= n; i++) {
        y = substr(key[i], 1, 4) + 0; m = substr(key[i], 5, 2) + 0; d = substr(key[i], 7, 2) + 0
        day = dn(y, m, d); age = now - day
        p = prefix(name[i])
        dk = p "|d" day; wk = p "|w" int(day / 7); mk = p "|m" (y * 100 + m)
        tier = ""
        if (!(p in first)) { first[p] = 1; tier = "new" }
        else if (age < 2) tier = "2d"
        else if (age < days && !(dk in seen)) tier = "day"
        else if (age < weeks * 7 && !(wk in seen)) tier = "week"
        else if (age < months * 31 && !(mk in seen)) tier = "month"
        if (tier == "") { print "drop - " name[i]; continue }
        seen[dk] = 1; seen[wk] = 1; seen[mk] = 1
        print "keep " tier " " name[i]
    }
}
