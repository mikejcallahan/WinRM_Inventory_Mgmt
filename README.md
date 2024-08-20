1. Requires winrm to be configured on all target machines. Make a GPO for using PSRemoting over https or restrict code execution another way (script has a restrict server option). To use this over default http, setup GPO with firewall IP restriction.  Authenticate using admin account with appropriate permissions. Needs to be run from a local file path on a server you can access from targets using \\servername\ currently.
2. Open in powershell_ise.exe on server. 
3. call initialize_inventory -start for interactive sequence to add PCs and begin querying PCs on your domain network.
