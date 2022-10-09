#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <adminmenu>

#define PLUGIN_VERSION "3.0"

public Plugin myinfo = {
	name = "WatchList", 
	author = "Dmustanger (updated by ampere)", 
	description = "Sets players to a WatchList.", 
	version = PLUGIN_VERSION, 
	url = "http://thewickedclowns.net"
}

int iadmin = (1 << 2);
int iWatchlistAnnounce = 3;
int targets[MAXPLAYERS];
int iprune = 0;

Database g_DB;

ConVar
CvarHostIp, 
CvarPort, 
CvarWatchlistAnnounceInterval, 
CvarWatchlistSound, 
CvarWatchlistLog, 
CvarWatchlistAdmin, 
CvarWatchlistAnnounce, 
CvarWatchlistPrune, 
CvarAnnounceAdminJoin;

TopMenu hTopMenu;
Handle WatchlistTimer;

char glogFile[PLATFORM_MAX_PATH];
char gServerIp[200];
char gServerPort[100];

bool IsMYSQL = true;
bool IsSoundOn = true;
bool IsLogOn = false;
bool IsAdminJoinOn = false;

char WatchlistSound[32] = "resource/warning.wav";

public void OnPluginStart() {
	BuildPath(Path_SM, glogFile, sizeof(glogFile), "logs/watchlist.log");
	
	CreateConVar("watchlist2_version", PLUGIN_VERSION, "WatchList Version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
	
	LoadTranslations("watchlist.phrases");
	LoadTranslations("common.phrases");
	
	Database.Connect(sqlGotDatabase, "watchlist");
	
	RegAdminCmd("watchlist_query", Command_Watchlist_Query, ADMFLAG_KICK, "watchlist_query \"steam_id | online\"", "Queries the Watchlist. Leave blank to search all.");
	RegAdminCmd("watchlist_add", Command_Watchlist_Add, ADMFLAG_KICK, "watchlist_add \"steam_id | #userid | name\" \"reason\"", "Adds a player to the watchlist.");
	RegAdminCmd("watchlist_remove", Command_Watchlist_Remove, ADMFLAG_KICK, "watchlist_remove \"steam_id | #userid | name\"", "Removes a player from the watchlist.");
	
	CvarHostIp = FindConVar("hostip");
	CvarPort = FindConVar("hostport");
	
	CvarWatchlistAnnounceInterval = CreateConVar("watchlist_announce_interval", "1.0", "Controls how often users on the watchlist \nwho are currently on the server are announced. \nThe time is specified in whole minutes (1.0...10.0).", FCVAR_NONE, true, 1.0, true, 10.0);
	CvarWatchlistSound = CreateConVar("watchlist_sound_enabled", "1", "Plays a warning sound to admins when \na WatchList player is announced. \n1 to Enable. \n0 to Disable.");
	CvarWatchlistLog = CreateConVar("watchlist_log_enabled", "0", "Enables logging. \n1 to Enable. \n0 to Disable.");
	CvarWatchlistAdmin = CreateConVar("watchlist_adminflag", "c", "Choose the admin flag that admins must have to use the watchlist. \nFind more flags at http://wiki.alliedmods.net/Adding_Admins_(SourceMod)#Levels");
	CvarWatchlistAnnounce = CreateConVar("watchlist_announce", "3", "1 Announce only when a player on the Watchlist joins and leaves the server. \n2 Announce every x amount of mins set by watchlist_announce_interval. \n3 Both 1 and 2. \n0 Disables announcing.");
	CvarWatchlistPrune = CreateConVar("watchlist_auto_delete", "0", "Controls how long in days to keep a player \non the watchlist before it is auto deleted. \n0 to Disable.");
	CvarAnnounceAdminJoin = CreateConVar("watchlist_admin_join", "0", "If set to 1, when a admin joins he will get a list of players on the watchlist that are on the server in the console.");
	
	CvarWatchlistAnnounceInterval.AddChangeHook(WatchlistAnnounceIntChange);
	CvarWatchlistSound.AddChangeHook(WatchlistSoundChange);
	CvarWatchlistLog.AddChangeHook(WatchlistLogChange);
	CvarWatchlistAdmin.AddChangeHook(WatchlistAdminChange);
	CvarWatchlistAnnounce.AddChangeHook(WatchlistAnnounceChange);
	CvarWatchlistPrune.AddChangeHook(WatchlistPruneChange);
	CvarAnnounceAdminJoin.AddChangeHook(AnnounceAdminJoinChange);
	
	WatchlistTimer = CreateTimer(60.0, ShowWatchlist, INVALID_HANDLE, TIMER_REPEAT);
	
	AutoExecConfig(true, "watchlist");
}


public void GetIpPort() {
	char sServerIp[100];
	char sServerPort[50];
	char sqlServerIp[200];
	char sqlServerPort[100];
	char ip[4];
	
	int longip = GetConVarInt(CvarHostIp);
	
	ip[0] = (longip >> 24) & 0x000000FF;
	ip[1] = (longip >> 16) & 0x000000FF;
	ip[2] = (longip >> 8) & 0x000000FF;
	ip[3] = longip & 0x000000FF;
	
	Format(sServerIp, sizeof(sServerIp), "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
	
	CvarPort.GetString(sServerPort, sizeof(sServerPort));
	
	g_DB.Escape(sServerIp, sqlServerIp, sizeof(sqlServerIp));
	g_DB.Escape(sServerPort, sqlServerPort, sizeof(sqlServerPort));
	strcopy(gServerIp, sizeof(gServerIp), sqlServerIp);
	strcopy(gServerPort, sizeof(gServerPort), sqlServerPort);
}

public void sqlGotDatabase(Database db, const char[] error, any data) {
	if (db == null) {
		SetFailState(error);
	}
	
	g_DB = db;
	sqldbtable();
	GetIpPort();
}

void sqldbtable() {
	char sdbtype[64];
	char squery[256];
	char query[256];
	
	g_DB.Driver.GetIdentifier(sdbtype, sizeof(sdbtype));
	
	if (StrEqual(sdbtype, "sqlite", false)) {
		IsMYSQL = false;
		g_DB.Format(squery, sizeof(squery), 
			"CREATE TABLE IF NOT EXISTS watchlist2 "...
			"(ingame INTEGER NOT NULL, "...
			"steamid TEXT PRIMARY KEY ON CONFLICT REPLACE, "...
			"serverip TEXT, serverport TEXT, reason TEXT NOT NULL, "...
			"name TEXT, date TEXT NOT NULL, date_last_seen TEXT NOT NULL);");
		
		g_DB.Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS watchlist_info (stored_date TEXT);");
	}
	else {
		IsMYSQL = true;
		g_DB.Format(squery, sizeof(squery), 
			"CREATE TABLE IF NOT EXISTS watchlist2 "...
			"(ingame INT NOT NULL, steamid VARCHAR(50) NOT NULL, "...
			"serverip VARCHAR(40), serverport VARCHAR(20), reason TEXT NOT NULL, "...
			"name VARCHAR(100), date DATE, date_last_seen DATE, PRIMARY KEY (steamid)) ENGINE = InnoDB;");
		g_DB.Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS watchlist_info (stored_date DATE)ENGINE = InnoDB;");
	}
	
	g_DB.Query(sqlT_Generic, query);
	g_DB.Query(sqlT_Generic, squery);
}

public void sqlT_Generic(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
}

public Action ShowWatchlist(Handle timer, Handle pack) {
	char squery[256];
	g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE serverip = '%s' AND serverport = '%s' AND ingame > 0", gServerIp, gServerPort);
	g_DB.Query(sqlT_ShowWatchlist, squery);
}

public void sqlT_ShowWatchlist(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	while (results.FetchRow()) {
		char sqlsteam[130];
		int userid = results.FetchInt(0);
		int client = GetClientOfUserId(userid);
		results.FetchString(1, sqlsteam, sizeof(sqlsteam));
		if (IsClientInGame(client) && !IsFakeClient(client)) {
			char ssteam[64];
			GetClientAuthId(client, AuthId_Steam2, ssteam, sizeof(ssteam));
			
			if (StrEqual(ssteam, sqlsteam, false) && iWatchlistAnnounce >= 2)
			{
				char sname[MAX_NAME_LENGTH];
				char sqlreason[256];
				char stext[256];
				GetClientName(client, sname, sizeof(sname));
				results.FetchString(4, sqlreason, sizeof(sqlreason));
				Format(stext, sizeof(stext), "%T", "Watchlist_Timer_Announce", LANG_SERVER, sname, ssteam, sqlreason);
				PrintToAdmins(stext);
			}
			else
			{
				DeactivateClient(sqlsteam);
			}
		}
		else
		{
			DeactivateClient(sqlsteam);
		}
	}
}

public void PrintToAdmins(const char[] stext) {
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i) && !IsClientTimingOut(i) && GetUserFlagBits(i) & iadmin)
		{
			PrintToChat(i, "%s", stext);
			if (IsSoundOn)
			{
				EmitSoundToClient(i, WatchlistSound);
			}
		}
	}
}

public void DeactivateClient(const char[] sqlsteam) {
	char squery[256];
	g_DB.Format(squery, sizeof(squery), "UPDATE watchlist2 SET ingame = 0, serverip = '0.0.0.0', serverport = '00000' WHERE steamid = '%s'", sqlsteam);
	g_DB.Query(sqlT_Generic, squery);
}

public void OnMapStart() {
	PrecacheSound(WatchlistSound, true);
	if (iprune > 0) {
		char squery[256];
		g_DB.Format(squery, sizeof(squery), "%s", IsMYSQL ? "SELECT CURDATE()" : "SELECT date('now')");
		g_DB.Query(sqlT_PruneDatabase, squery);
	}
}

public void sqlT_PruneDatabase(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	if (!results.FetchRow()) {
		return;
	}
	
	char snewdate[25];
	results.FetchString(0, snewdate, sizeof(snewdate));
	DataPack dbprune = new DataPack();
	dbprune.WriteString(snewdate);
	char squery[256];
	g_DB.Format(squery, sizeof(squery), "SELECT stored_date FROM watchlist_info");
	g_DB.Query(sqlT_PruneDatabaseCmp, squery, dbprune);
}

public void sqlT_PruneDatabaseCmp(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char squery[256];
	if (results.FetchRow()) {
		char sqldate[25];
		char newdate[25];
		results.FetchString(0, sqldate, sizeof(sqldate));
		pack.Reset();
		pack.ReadString(newdate, sizeof(newdate));
		if (!StrEqual(sqldate, newdate, false)) {
			PruneDatabase();
			if (IsMYSQL) {
				g_DB.Format(squery, sizeof(squery), "UPDATE watchlist_info SET stored_date = CURDATE()");
			}
			else {
				g_DB.Format(squery, sizeof(squery), "UPDATE watchlist_info SET stored_date = date('now')");
			}
			g_DB.Query(sqlT_Generic, squery);
		}
	}
	else {
		PruneDatabase();
		if (IsMYSQL) {
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist_info (stored_date) VALUES (CURDATE())");
		}
		else {
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist_info (stored_date) VALUES (date('now'))");
		}
		g_DB.Query(sqlT_Generic, squery);
	}
	
	delete pack;
}

void PruneDatabase() {
	char squery[256];
	if (IsMYSQL) {
		g_DB.Format(squery, sizeof(squery), "DELETE FROM watchlist2 WHERE DATE_SUB(CURDATE(), INTERVAL %i DAY) >= date", iprune);
	}
	else {
		g_DB.Format(squery, sizeof(squery), "DELETE FROM watchlist2 WHERE date('now', '-%i DAY') >= date", iprune);
	}
	
	g_DB.Query(sqlT_Generic, squery);
	
	if (IsLogOn) {
		LogToFile(glogFile, "Database Pruned.");
	}
}

public void OnClientPostAdminCheck(int client) {
	if (!IsFakeClient(client)) {
		char squery[256];
		int userid = GetClientUserId(client);
		if (GetUserFlagBits(client) & iadmin && IsAdminJoinOn) {
			g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE serverip = '%s' AND serverport = '%s' AND ingame > 0", gServerIp, gServerPort);
			g_DB.Query(sqlT_AdminJoinQuery, squery, userid);
		}
		else {
			char ssteam[64];
			char sqlsteam[130];
			GetClientAuthId(client, AuthId_Steam2, ssteam, sizeof(ssteam));
			g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
			g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
			g_DB.Query(sqlT_CheckUser, squery, userid);
		}
	}
}

public void sqlT_AdminJoinQuery(Database db, DBResultSet results, const char[] error, int userid) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char stext[256];
	int client = GetClientOfUserId(userid);
	Format(stext, sizeof(stext), "%T", "Watchlist_Query_Header", client);
	bool nodata = true;
	
	PrintToConsole(client, stext);
	
	while (results.FetchRow()) {
		char sqlsteamid[130];
		char sqlname[100];
		char sqlreason[256];
		char sqldate[25];
		results.FetchString(1, sqlsteamid, sizeof(sqlsteamid));
		results.FetchString(5, sqlname, sizeof(sqlname));
		results.FetchString(4, sqlreason, sizeof(sqlreason));
		results.FetchString(7, sqldate, sizeof(sqldate));
		PrintToConsole(client, "%s, %s, %s, %s", sqlsteamid, sqlname, sqldate, sqlreason);
		if (nodata) {
			nodata = false;
		}
	}
	
	if (nodata) {
		PrintToConsole(client, "%T", "Watchlist_Query_Empty", client);
	}
	else {
		PrintToChat(client, "%t", "Watchlist_Admin_Join", client);
		if (IsSoundOn) {
			EmitSoundToClient(client, WatchlistSound);
		}
	}
	
	PrintToConsole(client, stext);
}

public void sqlT_CheckUser(Database db, DBResultSet results, const char[] error, int userid) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	if (!results.FetchRow()) {
		return;
	}
	
	int client = GetClientOfUserId(userid);
	if (IsClientConnected(client) && !IsFakeClient(client) && IsClientInGame(client) && !IsClientTimingOut(client) && !IsClientInKickQueue(client)) {
		char sname[MAX_NAME_LENGTH];
		char sqlname[100];
		char ssteam[64];
		char sqlsteam[130];
		char sqlreason[512];
		char squery[256];
		char stext[256];
		
		GetClientName(client, sname, sizeof(sname));
		g_DB.Escape(sname, sqlname, sizeof(sqlname));
		GetClientAuthId(client, AuthId_Steam2, ssteam, sizeof(ssteam));
		g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
		results.FetchString(4, sqlreason, sizeof(sqlreason));
		Format(stext, sizeof(stext), "%T", "Watchlist_Player_Join", LANG_SERVER, sname, sqlsteam, sqlreason);
		
		if ((iWatchlistAnnounce == 1) || (iWatchlistAnnounce == 3)) {
			PrintToAdmins(stext);
		}
		if (IsLogOn) {
			LogToFile(glogFile, stext);
		}
		if (IsMYSQL) {
			g_DB.Format(squery, sizeof(squery), "UPDATE watchlist2 SET ingame = %i, serverip = '%s', serverport = '%s', "...
				"name = '%s', date_last_seen = CURDATE() WHERE steamid = '%s'", userid, gServerIp, gServerPort, sqlname, sqlsteam);
		}
		else {
			g_DB.Format(squery, sizeof(squery), "UPDATE watchlist2 SET ingame = %i, serverip = '%s', serverport = '%s', "...
				"name = '%s', date_last_seen = date('now') WHERE steamid = '%s'", userid, gServerIp, gServerPort, sqlname, sqlsteam);
		}
		
		g_DB.Query(sqlT_Generic, squery);
	}
}

public void OnClientDisconnect(int client) {
	if (IsFakeClient(client)) {
		return;
	}
	
	char sname[MAX_NAME_LENGTH];
	char ssteam[64];
	char sqlsteam[130];
	char squery[256];
	GetClientName(client, sname, sizeof(sname));
	GetClientAuthId(client, AuthId_Steam2, ssteam, sizeof(ssteam));
	g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
	g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
	DataPack clientdc = new DataPack();
	clientdc.WriteString(sqlsteam);
	clientdc.WriteString(sname);
	g_DB.Query(sqlT_ClientDC, squery, clientdc);
}

public void sqlT_ClientDC(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	if (!results.FetchRow()) {
		delete pack;
		return;
	}
	
	char sqlsteam[130];
	char sname[100];
	char stext[256];
	pack.Reset();
	pack.ReadString(sqlsteam, sizeof(sqlsteam));
	pack.ReadString(sname, sizeof(sname));
	Format(stext, sizeof(stext), "%T", "Watchlist_Player_Leave", LANG_SERVER, sname, sqlsteam);
	if ((iWatchlistAnnounce == 1) || (iWatchlistAnnounce == 3)) {
		PrintToAdmins(stext);
	}
	if (IsLogOn) {
		LogToFile(glogFile, stext);
	}
	DeactivateClient(sqlsteam);
	delete pack;
}

public Action Command_Watchlist_Query(int client, int args) {
	char squery[256];
	if (args > 0) {
		char ssteam[64];
		GetCmdArg(1, ssteam, sizeof(ssteam));
		if (StrEqual(ssteam, "online", false)) {
			g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE serverip = '%s' AND serverport = '%s' AND ingame > 0", gServerIp, gServerPort);
		}
		else if (StrContains(ssteam, "STEAM_", false) != -1) {
			if (strlen(ssteam) < 10) {
				ReplyToCommand(client, "USAGE: watchlist_query \"steam_id\". Be sure to use quotes to query a steamid.");
				return Plugin_Handled;
			}
			else {
				char sqlsteam[130];
				g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
				g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
			}
		}
		else {
			ReplyToCommand(client, "USAGE: watchlist_query \"steam_id | online\". Leave blank to search all.");
			return Plugin_Handled;
		}
	}
	else {
		g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2");
	}
	g_DB.Query(sqlT_WatchlistQuery, squery, client);
	return Plugin_Handled;
}

public void sqlT_WatchlistQuery(Database db, DBResultSet results, const char[] error, int idata) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char stext[256];
	Format(stext, sizeof(stext), "%T", "Watchlist_Query_Header", idata);
	bool nodata = true;
	PrintToConsole(idata, stext);
	while (results.FetchRow()) {
		char sqlsteamid[130];
		char sqlname[100];
		char sqlreason[256];
		char sqldate[25];
		results.FetchString(1, sqlsteamid, sizeof(sqlsteamid));
		results.FetchString(5, sqlname, sizeof(sqlname));
		results.FetchString(4, sqlreason, sizeof(sqlreason));
		results.FetchString(7, sqldate, sizeof(sqldate));
		PrintToConsole(idata, "%s, %s, %s, %s", sqlsteamid, sqlname, sqldate, sqlreason);
		if (nodata) {
			nodata = false;
		}
	}
	if (nodata) {
		PrintToConsole(idata, "%T", "Watchlist_Query_Empty", idata);
	}
	PrintToConsole(idata, stext);
}

public Action Command_Watchlist_Add(int client, int args) {
	if (args < 2) {
		ReplyToCommand(client, "USAGE: watchlist_add \"steam_id | #userid | name\" \"reason\"");
		return Plugin_Handled;
	}
	
	char splayerid[64];
	char ssteam[64];
	int target = -1;
	GetCmdArg(1, splayerid, sizeof(splayerid));
	if (StrContains(splayerid, "STEAM_", false) != -1) {
		if (strlen(splayerid) < 10) {
			ReplyToCommand(client, "USAGE: watchlist_add \"steam_id | #userid | name\" \"reason\"");
			return Plugin_Handled;
		}
		else {
			ssteam = splayerid;
		}
	}
	else
	{
		target = FindTarget(client, splayerid);
		if (target > 0)
		{
			GetClientAuthId(target, AuthId_Steam2, ssteam, sizeof(ssteam));
		}
		else
		{
			ReplyToTargetError(client, COMMAND_TARGET_NOT_IN_GAME);
			return Plugin_Handled;
		}
	}
	char sreason[256];
	char pclient[25];
	char ptarget[25];
	char sqlsteam[130];
	char squery[256];
	GetCmdArg(2, sreason, sizeof(sreason));
	g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
	g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
	IntToString(client, pclient, sizeof(pclient));
	IntToString(target, ptarget, sizeof(ptarget));
	DataPack CheckWatchlistAddPack = new DataPack();
	CheckWatchlistAddPack.WriteString(pclient);
	CheckWatchlistAddPack.WriteString(ptarget);
	CheckWatchlistAddPack.WriteString(sqlsteam);
	CheckWatchlistAddPack.WriteString(sreason);
	g_DB.Query(sqlT_CommandWatchlistAdd, squery, CheckWatchlistAddPack);
	return Plugin_Handled;
}

public void sqlT_CommandWatchlistAdd(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char pclient[25];
	char ptarget[25];
	char sqlsteam[130];
	char preason[256];
	char sqlreason[256];
	
	pack.Reset();
	pack.ReadString(pclient, sizeof(pclient));
	pack.ReadString(ptarget, sizeof(ptarget));
	pack.ReadString(sqlsteam, sizeof(sqlsteam));
	pack.ReadString(preason, sizeof(preason));
	int client = StringToInt(pclient);
	if (results.FetchRow()) {
		char stext[256];
		results.FetchString(4, sqlreason, sizeof(sqlreason));
		Format(stext, sizeof(stext), "%T", "Watchlist_Add", client, sqlsteam, sqlreason);
		if (client > 0) {
			PrintToChat(client, stext);
		}
		else {
			ReplyToCommand(client, stext);
		}
	}
	else {
		int target = StringToInt(ptarget);
		WatchlistAdd(client, target, sqlsteam, preason);
	}
	
	delete pack;
}

void WatchlistAdd(int client, int target, char[] sqlsteam, char[] sreason) {
	char pclient[25];
	char sqlreason[512];
	char squery[512];
	g_DB.Escape(sreason, sqlreason, sizeof(sqlreason));
	if (target > 0)
	{
		char splayer_name[MAX_NAME_LENGTH];
		char sqlplayer_name[101];
		GetClientName(target, splayer_name, sizeof(splayer_name));
		g_DB.Escape(splayer_name, sqlplayer_name, sizeof(sqlplayer_name));
		int userid = 0;
		if (IsClientConnected(target)) {
			userid = GetClientUserId(target);
		}
		if (IsMYSQL) {
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist2 (ingame, steamid, serverip, serverport, reason, name, date, date_last_seen) VALUES (%i, '%s', '%s', '%s', '%s', '%s', CURDATE(), CURDATE())", userid, sqlsteam, gServerIp, gServerPort, sqlreason, sqlplayer_name);
		}
		else {
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist2 (ingame, steamid, serverip, serverport, reason, name, date, date_last_seen) VALUES (%i, '%s', '%s', '%s', '%s', '%s', date('now'), date('now'))", userid, sqlsteam, gServerIp, gServerPort, sqlreason, sqlplayer_name);
		}
	}
	else
	{
		if (IsMYSQL)
		{
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist2 (ingame, steamid, serverip, serverport, reason, name, date, date_last_seen) VALUES (%i, '%s', '0.0.0.0', '00000', '%s', 'unknown', CURDATE(), CURDATE())", target, sqlsteam, sqlreason);
		}
		else
		{
			g_DB.Format(squery, sizeof(squery), "INSERT INTO watchlist2 (ingame, steamid, serverip, serverport, reason, name, date, date_last_seen) VALUES (%i, '%s', '0.0.0.0', '00000', '%s', 'unknown', date('now'), date('now'))", target, sqlsteam, sqlreason);
		}
	}
	IntToString(client, pclient, sizeof(pclient));
	DataPack WatchlistAddPack = new DataPack();
	WatchlistAddPack.WriteString(pclient);
	WatchlistAddPack.WriteString(sqlsteam);
	WatchlistAddPack.WriteString(sqlreason);
	g_DB.Query(sqlT_WatchlistAdd, squery, WatchlistAddPack);
}

public void sqlT_WatchlistAdd(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char stext[256];
	char pclient[25];
	char sqlsteam[130];
	char sqlreason[256];
	pack.Reset();
	pack.ReadString(pclient, sizeof(pclient));
	pack.ReadString(sqlsteam, sizeof(sqlsteam));
	pack.ReadString(sqlreason, sizeof(sqlreason));
	delete pack;
	int client = StringToInt(pclient);
	
	Format(stext, sizeof(stext), "%T", "Watchlist_Add_Success", client, sqlsteam, sqlreason);
	if (IsLogOn)
	{
		LogToFile(glogFile, stext);
	}
	
	PrintToChat(client, stext);
}

public Action Command_Watchlist_Remove(int client, int args) {
	int target = -1;
	if (GetCmdArgs() < 1)
	{
		ReplyToCommand(client, "USAGE: watchlist_remove \"steam_id | #userid | name\"");
		return Plugin_Handled;
	}
	else
	{
		char splayer_id[50];
		char ssteam[64];
		GetCmdArg(1, splayer_id, sizeof(splayer_id));
		if (StrContains(splayer_id, "STEAM_", false) != -1)
		{
			if (strlen(splayer_id) < 10)
			{
				ReplyToCommand(client, "USAGE: watchlist_remove \"steam_id | #userid | name\"");
				return Plugin_Handled;
			}
			else
			{
				ssteam = splayer_id;
			}
		}
		else
		{
			target = FindTarget(client, splayer_id);
			if (target > 0)
			{
				GetClientAuthId(target, AuthId_Steam2, ssteam, sizeof(ssteam));
			}
			else
			{
				ReplyToTargetError(client, COMMAND_TARGET_NOT_IN_GAME);
				return Plugin_Handled;
			}
		}
		char pclient[25];
		char sqlsteam[130];
		char squery[256];
		IntToString(client, pclient, sizeof(pclient));
		g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
		g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
		DataPack CheckWatchlistRemovePack = new DataPack();
		CheckWatchlistRemovePack.WriteString(pclient);
		CheckWatchlistRemovePack.WriteString(sqlsteam);
		g_DB.Query(sqlT_CommandWatchlistRemove, squery, CheckWatchlistRemovePack);
		return Plugin_Handled;
	}
}

public void sqlT_CommandWatchlistRemove(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char pclient[25];
	char sqlsteam[130];
	pack.Reset();
	pack.ReadString(pclient, sizeof(pclient));
	pack.ReadString(sqlsteam, sizeof(sqlsteam));
	int client = StringToInt(pclient);
	if (results.FetchRow()) {
		WatchlistRemove(client, sqlsteam);
	}
	else {
		char stext[256];
		Format(stext, sizeof(stext), "%T", "Watchlist_Remove", client, sqlsteam);
		if (client > 0) {
			PrintToChat(client, stext);
		}
		else {
			ReplyToCommand(client, stext);
		}
	}
	
	delete pack;
}

void WatchlistRemove(int client, char[] sqlsteam) {
	char pclient[25];
	char squery[256];
	g_DB.Format(squery, sizeof(squery), "DELETE FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
	IntToString(client, pclient, sizeof(pclient));
	DataPack WatchlistRemovePack = new DataPack();
	WatchlistRemovePack.WriteString(pclient);
	WatchlistRemovePack.WriteString(sqlsteam);
	g_DB.Query(sqlT_WatchlistRemove, squery, WatchlistRemovePack);
}

public void sqlT_WatchlistRemove(Database db, DBResultSet results, const char[] error, DataPack pack) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	char stext[256];
	char pclient[25];
	char sqlsteam[130];
	pack.Reset();
	pack.ReadString(pclient, sizeof(pclient));
	pack.ReadString(sqlsteam, sizeof(sqlsteam));
	delete pack;
	int client = StringToInt(pclient);
	
	Format(stext, sizeof(stext), "%T", "Watchlist_Remove_Success", client, sqlsteam);
	if (IsLogOn) {
		LogToFile(glogFile, stext);
	}
	if (client > 0) {
		PrintToChat(client, stext);
	}
	else {
		ReplyToCommand(client, stext);
	}
}

public void WatchlistAnnounceIntChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	if (WatchlistTimer != null) {
		delete WatchlistTimer;
	}
	WatchlistTimer = CreateTimer(StringToInt(newVal) * 60.0, ShowWatchlist, INVALID_HANDLE, TIMER_REPEAT);
}

public void WatchlistSoundChange(ConVar cvar, const char[] oldValue, const char[] newValue) {
	IsSoundOn = cvar.BoolValue;
}

public void WatchlistLogChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	IsLogOn = cvar.BoolValue;
}

public void WatchlistAdminChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	iadmin = ReadFlagString(newVal);
	AddCommandOverride("watchlist_query", Override_Command, iadmin);
	AddCommandOverride("watchlist_add", Override_Command, iadmin);
	AddCommandOverride("watchlist_remove", Override_Command, iadmin);
}

public void WatchlistAnnounceChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	if (cvar.IntValue <= 0) {
		iWatchlistAnnounce = 0;
	}
	else if (cvar.IntValue >= 3) {
		iWatchlistAnnounce = 3;
	}
	else {
		iWatchlistAnnounce = StringToInt(newVal);
	}
}

public void WatchlistPruneChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	iprune = cvar.IntValue;
}

public void AnnounceAdminJoinChange(ConVar cvar, const char[] oldVal, const char[] newVal) {
	IsAdminJoinOn = cvar.BoolValue;
}

public void OnAllPluginsLoaded() {
	TopMenu topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null)) {
		OnAdminMenuReady(topmenu);
	}
}

public void OnAdminMenuReady(Handle topmenu) {
	if (topmenu == hTopMenu) {
		return;
	}
	
	hTopMenu = view_as<TopMenu>(topmenu);
	TopMenuObject player_commands = hTopMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);
	if (player_commands != INVALID_TOPMENUOBJECT) {
		AddToTopMenu(hTopMenu, "watchlist_add", TopMenuObject_Item, MenuWatchlistAdd, player_commands, "watchlist_add");
		AddToTopMenu(hTopMenu, "watchlist_remove", TopMenuObject_Item, MenuWatchlistRemove, player_commands, "watchlist_remove");
	}
}

public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "adminmenu")) {
		hTopMenu = null;
	}
}

public void MenuWatchlistAdd(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength) {
	if (action == TopMenuAction_DisplayOption) {
		Format(buffer, maxlength, "%T", "Watchlist_Add_Menu", param, param);
	}
	else if (action == TopMenuAction_SelectOption) {
		WatchlistAddTargetMenu(param);
	}
}

void WatchlistAddTargetMenu(int client) {
	Menu menu = new Menu(MenuWatchlistAddTarget);
	char stitle[100];
	Format(stitle, sizeof(stitle), "%T", "Watchlist_Add_Menu", client, client);
	menu.SetTitle(stitle);
	menu.ExitBackButton = true;
	AddTargetsToMenu(menu, client, false, false);
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuWatchlistAddTarget(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hTopMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(hTopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		char sinfo[32], sname[MAX_NAME_LENGTH];
		int userid, target;
		menu.GetItem(param2, sinfo, sizeof(sinfo), _, sname, sizeof(sname));
		userid = StringToInt(sinfo);
		if ((target = GetClientOfUserId(userid)) == 0 || !CanUserTarget(param1, target))
		{
			ReplyToTargetError(param1, COMMAND_TARGET_NOT_IN_GAME);
		}
		else
		{
			targets[param1] = target;
			WatchlistReasonMenu(param1);
		}
	}
}

void WatchlistReasonMenu(int client) {
	Menu menu = new Menu(WatchlistAddReasonMenu);
	char stitle[100];
	Format(stitle, sizeof(stitle), "%T", "Watchlist_Add_Menu", client, client);
	SetMenuTitle(menu, stitle);
	SetMenuExitBackButton(menu, true);
	AddMenuItem(menu, "Aimbot", "Aimbot");
	AddMenuItem(menu, "Speedhack", "Speedhack");
	AddMenuItem(menu, "Spinbot", "Spinbot");
	AddMenuItem(menu, "Team Killing", "Team Killing");
	AddMenuItem(menu, "Mic Spam", "Mic Spam");
	AddMenuItem(menu, "Breaking server rules", "Breaking server rules");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int WatchlistAddReasonMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hTopMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(hTopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		char sreason[256];
		char sreason_name[256];
		char ssteam[64];
		char sqlsteam[130];
		char squery[256];
		char pclient[25];
		char ptarget[25];
		int target = targets[param1];
		GetClientAuthId(target, AuthId_Steam2, ssteam, sizeof(ssteam));
		GetMenuItem(menu, param2, sreason, sizeof(sreason), _, sreason_name, sizeof(sreason_name));
		g_DB.Escape(ssteam, sqlsteam, sizeof(sqlsteam));
		g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2 WHERE steamid = '%s'", sqlsteam);
		IntToString(param1, pclient, sizeof(pclient));
		IntToString(target, ptarget, sizeof(ptarget));
		DataPack CheckWatchlistAddReasonMenu = new DataPack();
		CheckWatchlistAddReasonMenu.WriteString(pclient);
		CheckWatchlistAddReasonMenu.WriteString(ptarget);
		CheckWatchlistAddReasonMenu.WriteString(sqlsteam);
		CheckWatchlistAddReasonMenu.WriteString(sreason);
		g_DB.Query(sqlT_CommandWatchlistAdd, squery, CheckWatchlistAddReasonMenu);
	}
}

public void MenuWatchlistRemove(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength) {
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "%T", "Watchlist_Remove_Menu", param, param);
	}
	else if (action == TopMenuAction_SelectOption)
	{
		FindWatchlistTargetsMenu(param);
	}
}

void FindWatchlistTargetsMenu(int client) {
	char squery[256];
	g_DB.Format(squery, sizeof(squery), "SELECT * FROM watchlist2");
	g_DB.Query(sqlWatchlistRemoveTargetMenu, squery, client);
}

public void sqlWatchlistRemoveTargetMenu(Database db, DBResultSet results, const char[] error, int client) {
	if (results == null && IsLogOn) {
		LogToFile("%T", "ERROR2", LANG_SERVER, error);
	}
	
	Menu menu = new Menu(MenuWatchlistRemoveTarget);
	char stitle[100];
	Format(stitle, sizeof(stitle), "%T", "Watchlist_Remove_Menu", client, client);
	SetMenuTitle(menu, stitle);
	SetMenuExitBackButton(menu, true);
	bool noClients = true;
	while (results.FetchRow())
	{
		char starget[130];
		char sname[MAX_NAME_LENGTH];
		results.FetchString(5, sname, sizeof(sname));
		results.FetchString(1, starget, sizeof(starget));
		AddMenuItem(menu, starget, sname);
		if (noClients)
		{
			noClients = false;
		}
	}
	if (noClients)
	{
		char stext[256];
		Format(stext, sizeof(stext), "%T", "Watchlist_Query_Empty", client);
		AddMenuItem(menu, "noClients", stext);
	}
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuWatchlistRemoveTarget(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	}
	else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack && hTopMenu != INVALID_HANDLE) {
			DisplayTopMenu(hTopMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select) {
		char starget[130];
		char sjunk[256];
		menu.GetItem(param2, starget, sizeof(starget), _, sjunk, sizeof(sjunk));
		if (!strcmp(starget, "noClients", true)) {
			return;
		}
		else {
			char sqlsteam[130];
			g_DB.Escape(starget, sqlsteam, sizeof(sqlsteam));
			WatchlistRemove(param1, sqlsteam);
		}
	}
}





