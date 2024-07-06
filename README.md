1. Requires winrm to be configured on all target machines. Make a GPO for using PSRemoting over https or restrict code execution another way (script has a restrict server option). To use this over default http, setup GPO with firewall IP restriction.  Authenticate using admin account with appropriate permissions. Credentials are authenticated through Kerberos but commands are sent as plain text over http. 
3. Open in powershell_ise.exe on server.
4. Set variables appropriately
5. Run script to see options for running in a loop or otherwise.
