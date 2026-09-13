# after redeploy, with a world that has something in it:
az vm run-command invoke -g rg-valheim-server -n valheim-vm --command-id RunShellScript \
  --scripts 'docker compose -f /opt/valheim/docker-compose.yml stop -t 120' \
            '/opt/valheim/bin/sync.sh' \
            'journalctl -t valheim --no-pager | tail -5'
# want: "sync: pushed N files, pruned M stale"

# Destroy from page, Start again, then:
az vm run-command invoke -g rg-valheim-server -n valheim-vm --command-id RunShellScript \
  --scripts 'journalctl -t valheim --no-pager | grep restore' \
            'ls -la /opt/valheim/config/worlds_local/Midgard/'
# want: "restore: N world files" with N > 0, same _main.* set, THEN log in and
# check the hut is there