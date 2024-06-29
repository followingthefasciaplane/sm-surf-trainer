//this is not fully complete yet

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <momsurffix2>
//see: https://github.com/followingthefasciaplane/MomSurfFix-API/blob/master/addons/sourcemod/scripting/include/momsurffix2.inc

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0"
#define MAX_STATS_ENTRIES 100
#define MAX_PREDICTION_POINTS 10
#define STOP_EPSILON 0.1

public Plugin myinfo = {
    name = "Surf Trainer v2",
    author = "jessetooler",
    description = "a comprehensive plugin to help players improve their surfing skills",
    version = PLUGIN_VERSION,
    url = "https://www.youtube.com/channel/UCOR3vlkNkqymsrl4HPMHw0g"
};

// globals
float g_flTickInterval;
Handle g_hCheckClientsTimer;
float g_vLastSurfaceNormal[MAXPLAYERS + 1][3];

ConVar g_cvDebugMode;
ConVar g_cvPerfectBoardThreshold;
ConVar g_cvTraceDistance;
ConVar g_cvMaxSurfaceNormalZ;
ConVar g_cvMinSurfaceNormalZ;

float g_flLastProcessTime[MAXPLAYERS + 1];
bool g_bTouchingRamp[MAXPLAYERS + 1];
bool g_bJustStartedTouchingRamp[MAXPLAYERS + 1];
float g_vPreBoardVelocity[MAXPLAYERS + 1][3];
float g_vLastBumpVelocity[MAXPLAYERS + 1][3];
float g_vLastBumpOrigin[MAXPLAYERS + 1][3];
float g_flBoardEfficiencies[MAXPLAYERS + 1][MAX_STATS_ENTRIES];
int g_iBoardEfficiencyIndex[MAXPLAYERS + 1];
float g_flAverageSpeed[MAXPLAYERS + 1];
float g_flTotalAirTime[MAXPLAYERS + 1];
float g_flLastGroundTime[MAXPLAYERS + 1];
int g_iTotalBoards[MAXPLAYERS + 1];

float g_vInitialVelocity[MAXPLAYERS + 1][3];
float g_vBoardVelocity[MAXPLAYERS + 1][3];
float g_vFinalVelocity[MAXPLAYERS + 1][3];
bool g_bWaitingForClipVelocity[MAXPLAYERS + 1];
bool g_bWaitingForPostMove[MAXPLAYERS + 1];

int g_iBeamSprite;
Handle g_hHudSync;

public void OnPluginStart()
{
    LoadTranslations("surf_trainer.phrases");
    
    CreateConVar("sm_surftrainer_version", PLUGIN_VERSION, "Surf trainer version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
    Config_Init();
    Stats_Init();
    Visualization_Init();
    UI_Init();
    
    HookEvent("player_spawn", Event_PlayerSpawn);
    
    g_hCheckClientsTimer = CreateTimer(1.0, Timer_CheckClientsOnRamp, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
    
    g_flTickInterval = GetTickInterval();
    
    RegConsoleCmd("sm_surfstats", Command_SurfStats, "Display surf statistics");
    RegConsoleCmd("sm_surfsettings", Command_SurfSettings, "Open surf trainer settings menu");
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    Stats_ResetClientState(client);
    ZeroVector(g_vInitialVelocity[client]);
    ZeroVector(g_vBoardVelocity[client]);
    ZeroVector(g_vFinalVelocity[client]);
    ZeroVector(g_vLastSurfaceNormal[client]);
    g_bWaitingForClipVelocity[client] = false;
    g_bWaitingForPostMove[client] = false;
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    Stats_SaveClientStats(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client))
    {
        Stats_ResetClientState(client);
    }
}

public void OnPostThinkPost(int client)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        return;
    }

    float currentTime = GetGameTime();
    if (currentTime - Stats_GetLastProcessTime(client) < g_flTickInterval)
    {
        return;
    }

    Stats_SetLastProcessTime(client, currentTime);
    SimulatePlayerMovement(client);
}

void SimulatePlayerMovement(int client)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        return;
    }

    float currentVelocity[3], currentOrigin[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", currentVelocity);
    GetClientAbsOrigin(client, currentOrigin);

    float surfaceNormal[3];
    surfaceNormal = g_vLastSurfaceNormal[client];

    bool isOnSurfRamp = IsPlayerOnSurfRamp(client, surfaceNormal);

    if (isOnSurfRamp)
    {
        if (!Stats_IsTouchingRamp(client))
        {
            Stats_SetTouchingRamp(client, true);
            Stats_SetJustStartedTouchingRamp(client, true);
            Stats_SetPreBoardVelocity(client, currentVelocity);
        }
        else if (Stats_IsJustStartedTouchingRamp(client))
        {
            Stats_SetJustStartedTouchingRamp(client, false);
        }
    }
    else
    {
        Stats_SetTouchingRamp(client, false);
        Stats_SetJustStartedTouchingRamp(client, false);
    }

    Visualization_PredictedTrajectory(client, currentVelocity);

    if (Config_IsDebugMode())
    {
        float xyVelocity[3];
        xyVelocity[0] = currentVelocity[0];
        xyVelocity[1] = currentVelocity[1];
        xyVelocity[2] = 0.0;
        float xySpeed = GetVectorLength(xyVelocity);
        LogMessage("Player %N - Current XY Velocity: %.2f %.2f | XY Speed: %.2f", 
            client, xyVelocity[0], xyVelocity[1], xySpeed);
    }
}

void Visualization_PredictedTrajectory(int client, const float initialVelocity[3])
{
    float clientPos[3], clientMins[3], clientMaxs[3];
    GetClientAbsOrigin(client, clientPos);
    GetClientMins(client, clientMins);
    GetClientMaxs(client, clientMaxs);
    
    int color[4] = {0, 255, 0, 255};
    float beamWidth = 1.0;
    float beamLife = 0.1;
    
    float simulatedVelocity[3], simulatedPosition[3], prevPosition[3];
    CopyVector(initialVelocity, simulatedVelocity);
    CopyVector(clientPos, simulatedPosition);
    CopyVector(clientPos, prevPosition);
    
    for (int i = 1; i <= MAX_PREDICTION_POINTS; i++)
    {
        float nextSimulatedVelocity[3], nextSimulatedPosition[3];
        CopyVector(simulatedVelocity, nextSimulatedVelocity);
        CopyVector(simulatedPosition, nextSimulatedPosition);
        
        // simulate movement for this step
        SimulatePlayerStep(client, nextSimulatedVelocity, nextSimulatedPosition, clientMins, clientMaxs);
        
        TE_SetupBeamPoints(
            prevPosition, 
            nextSimulatedPosition, 
            g_iBeamSprite, 
            0,
            0,
            60,
            beamLife, 
            beamWidth, 
            beamWidth,
            1,
            0.0,
            color, 
            0
        );
        TE_SendToClient(client);
        
        CopyVector(nextSimulatedVelocity, simulatedVelocity);
        CopyVector(nextSimulatedPosition, prevPosition);
        CopyVector(nextSimulatedPosition, simulatedPosition);
    }

    char velocityText[128];
    float speed = GetVectorLength(simulatedVelocity);
    Format(velocityText, sizeof(velocityText), "%T", "PredictedSpeed", client, speed);
    PrintHintText(client, velocityText);
}

void SimulatePlayerStep(int client, float velocity[3], float position[3], const float mins[3], const float maxs[3])
{
    float gravity = GetEntPropFloat(client, Prop_Data, "m_flGravity");
    if (gravity == 0.0) gravity = 800.0; // default gravity
    
    float stepTime = GetTickInterval();
    
    // apply gravity
    velocity[2] -= gravity * stepTime;
    
    // calculate new position
    float newPosition[3];
    for (int i = 0; i < 3; i++)
    {
        newPosition[i] = position[i] + velocity[i] * stepTime;
    }
    
    // check for collision with world
    TR_TraceHullFilter(position, newPosition, mins, maxs, MASK_PLAYERSOLID, TraceFilter_World, client);
    
    if (TR_DidHit())
    {
        float endPosition[3], normal[3];
        TR_GetEndPosition(endPosition);
        TR_GetPlaneNormal(null, normal);
        
        // use IsPlayerOnSurfRamp to check if this is a surf ramp
        if (IsPlayerOnSurfRamp(client, normal))
        {
            // simulate surf physics
            float newVelocity[3];
            SimulateClipVelocity(velocity, normal, newVelocity, 1.0);
            CopyVector(newVelocity, velocity);
            
            // adjust position to slide along the surface
            float adjust = GetVectorDotProduct(velocity, normal) * stepTime;
            for (int i = 0; i < 3; i++)
            {
                endPosition[i] += normal[i] * adjust;
            }
        }
        else
        {
            // standard collision response
            SimulateClipVelocity(velocity, normal, velocity, 1.0);
        }
        
        CopyVector(endPosition, position);
    }
    else
    {
        CopyVector(newPosition, position);
    }
}

void SimulateClipVelocity(const float inVelocity[3], const float normal[3], float outVelocity[3], float overbounce)
{
    float backoff = GetVectorDotProduct(inVelocity, normal) * overbounce;

    for (int i = 0; i < 3; i++)
    {
        float change = normal[i] * backoff;
        outVelocity[i] = inVelocity[i] - change;
        
        if (outVelocity[i] > -STOP_EPSILON && outVelocity[i] < STOP_EPSILON)
            outVelocity[i] = 0.0;
    }

    // adjust if velocity is against normal
    float adjust = GetVectorDotProduct(outVelocity, normal);
    if (adjust < 0.0)
    {
        for (int i = 0; i < 3; i++)
        {
            outVelocity[i] -= (normal[i] * adjust);
        }
    }
}

public bool TraceFilter_World(int entity, int contentsMask, any data)
{
    return entity == 0 || (entity > MaxClients);
}

void AnalyzeBoard(int client, const float surfaceNormal[3])
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    float initialSpeed = GetVectorLength(g_vInitialVelocity[client]);
    float boardSpeed = GetVectorLength(g_vBoardVelocity[client]);
    float finalSpeed = GetVectorLength(g_vFinalVelocity[client]);

    float boardSpeedDiff = boardSpeed - initialSpeed;
    float finalSpeedDiff = finalSpeed - initialSpeed;

    float boardEfficiency = (boardSpeedDiff / initialSpeed) * 100.0;
    float overallEfficiency = (finalSpeedDiff / initialSpeed) * 100.0;

    // calculate the angle between velocity and surface normal
    float angle = RadToDeg(ArcCosine(GetVectorDotProduct(g_vFinalVelocity[client], surfaceNormal) / (finalSpeed * GetVectorLength(surfaceNormal))));

    LogMessage("AnalyzeBoard - Client: %d, InitialSpeed: %.2f, BoardSpeed: %.2f, FinalSpeed: %.2f, Angle: %.2f", client, initialSpeed, boardSpeed, finalSpeed, angle);

    AnalyzeBoardPerformance(client, boardSpeedDiff, finalSpeedDiff, boardEfficiency, overallEfficiency, angle);
}

void AnalyzeBoardPerformance(int client, float boardSpeedDiff, float finalSpeedDiff, float boardEfficiency, float overallEfficiency, float angle)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    bool isPerfectBoard = (boardSpeedDiff > 0 && finalSpeedDiff > 0 && (finalSpeedDiff - boardSpeedDiff) < Config_GetPerfectBoardThreshold());
    
    boardEfficiency = boardEfficiency > 100.0 ? 100.0 : boardEfficiency < 0.0 ? 0.0 : boardEfficiency;
    overallEfficiency = overallEfficiency > 100.0 ? 100.0 : overallEfficiency < 0.0 ? 0.0 : overallEfficiency;
    
    char speedFeedback[128], efficiencyFeedback[128], angleFeedback[128], overallFeedback[512];
    
    if (isPerfectBoard)
    {
        Format(speedFeedback, sizeof(speedFeedback), "%T", "PerfectBoard", client, finalSpeedDiff);
    }
    else
    {
        Format(speedFeedback, sizeof(speedFeedback), "%T", "ImprovementNeeded", client, finalSpeedDiff);
    }
    
    if (overallEfficiency >= boardEfficiency)
    {
        Format(efficiencyFeedback, sizeof(efficiencyFeedback), "%T", "GoodBoardExit", client);
    }
    else
    {
        Format(efficiencyFeedback, sizeof(efficiencyFeedback), "%T", "PoorBoardExit", client);
    }
    
    Format(angleFeedback, sizeof(angleFeedback), "%T", "SurfAngle", client, angle);
    
    Format(overallFeedback, sizeof(overallFeedback), "%T", "BoardAnalysis", client, speedFeedback, efficiencyFeedback, angleFeedback,"%T", "BoardEfficiency", client, boardEfficiency, "%T", "OverallEfficiency", client, overallEfficiency);
    
    UI_DisplayBoardAnalysis(client, overallFeedback, overallEfficiency);
    
    Stats_StoreEfficiency(client, overallEfficiency);
    Stats_UpdateAverageSpeed(client, GetVectorLength(g_vInitialVelocity[client]));
    Stats_UpdateAirTime(client, GetGameTime() - Stats_GetLastGroundTime(client));
}

public Action Timer_CheckClientsOnRamp(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && IsPlayerAlive(i))
        {
            float surfaceNormal[3];
            if (IsPlayerOnSurfRamp(i, surfaceNormal))
            {               
                if (Config_IsDebugMode())
                {
                    LogMessage("Player %N is on a surf ramp!", i);
                }
            }
        }
    }
    return Plugin_Continue;
}

public Action Command_SurfStats(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    UI_DisplaySurfStats(client);

    return Plugin_Handled;
}

public Action Command_SurfSettings(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    UI_OpenSettingsMenu(client);

    return Plugin_Handled;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client));
}

public void OnPluginEnd()
{
    if (g_hCheckClientsTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCheckClientsTimer);
        g_hCheckClientsTimer = INVALID_HANDLE;
    }

    // save all client stats
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Stats_SaveClientStats(i);
        }
    }

    // clean up other modules
    Config_Cleanup();
    Stats_Cleanup();
    Visualization_Cleanup();
    UI_Cleanup();
}

public void OnMapStart()
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    
    // load map-specific configurations
    Config_LoadMapConfig(currentMap);
    
    // reset statistics for the new map
    Stats_ResetMapStats();
    
    // precache necessary assets
    Visualization_PrecacheAssets();
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Stats_ResetClientState(i);
        }
    }
}

bool IsPlayerOnSurfRamp(int client, float surfaceNormal[3])
{
    float startPos[3], endPos[3], mins[3], maxs[3];
    GetClientAbsOrigin(client, startPos);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);

    float directions[5][3] = {
        {0.0, 0.0, -1.0},
        {1.0, 0.0, 0.0},
        {-1.0, 0.0, 0.0},
        {0.0, 1.0, 0.0},
        {0.0, -1.0, 0.0}
    };

    float eyeAngles[3], fw[3];
    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, fw, NULL_VECTOR, NULL_VECTOR);

    for (int i = 0; i < sizeof(directions); i++)
    {
        if (i == 1)
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] + fw[j] * Config_GetTraceDistance();
            }
        }
        else if (i == 2)
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] - fw[j] * Config_GetTraceDistance();
            }
        }
        else
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] + directions[i][j] * Config_GetTraceDistance();
            }
        }

        Handle trace = TR_TraceHullFilterEx(startPos, endPos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_World, client);

        if (TR_DidHit(trace))
        {
            TR_GetPlaneNormal(trace, surfaceNormal);

            if (surfaceNormal[2] < Config_GetMaxSurfaceNormalZ() && surfaceNormal[2] > Config_GetMinSurfaceNormalZ())
            {
                delete trace;
                return true;
            }
        }

        delete trace;
    }

    return false;
}

public Action MomSurfFix_OnBumpIteration(int client, int bumpcount, float velocity[3], float origin[3])
{
    if (bumpcount == 0)  // this is the initial bump
    {
        CopyVector(velocity, g_vInitialVelocity[client]);
        g_bWaitingForClipVelocity[client] = true;
    }
    return Plugin_Continue;
}

public Action MomSurfFix_OnClipVelocity(int client, float inVelocity[3], float normal[3], float &overbounce)
{
    if (g_bWaitingForClipVelocity[client])
    {
        CopyVector(inVelocity, g_vBoardVelocity[client]);
        CopyVector(normal, g_vLastSurfaceNormal[client]);
        g_bWaitingForClipVelocity[client] = false;
        g_bWaitingForPostMove[client] = true;
    }

    if (Config_IsDebugMode())
    {
        LogMessage("Player %N - Velocity clipped. InVelocity: %.2f %.2f %.2f, Normal: %.2f %.2f %.2f, Overbounce: %.2f",
            client,
            inVelocity[0], inVelocity[1], inVelocity[2],
            normal[0], normal[1], normal[2],
            overbounce);
    }
    return Plugin_Continue;
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int blocked, float endVelocity[3], float endOrigin[3], float allFraction)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    if (g_bWaitingForPostMove[client])
    {
        float surfaceNormal[3];
        surfaceNormal = g_vLastSurfaceNormal[client];
        CopyVector(endVelocity, g_vFinalVelocity[client]);
        AnalyzeBoard(client, surfaceNormal);
        g_bWaitingForPostMove[client] = false;
    }

    if (Config_IsDebugMode())
    {
        LogMessage("Player %N - Post-move. Blocked: %d, EndVelocity: %.2f %.2f %.2f, EndOrigin: %.2f %.2f %.2f, AllFraction: %.2f",
            client,
            blocked,
            endVelocity[0], endVelocity[1], endVelocity[2],
            endOrigin[0], endOrigin[1], endOrigin[2],
            allFraction);
    }
}

public void MomSurfFix_OnPlayerStuckOnRamp(int client, float velocity[3], float origin[3], float validPlane[3])
{
    UI_NotifyPlayerStuck(client);
    LogStuckEvent(client, velocity, origin, validPlane);
    CopyVector(validPlane, g_vLastSurfaceNormal[client]);
}

void LogStuckEvent(int client, const float velocity[3], const float origin[3], const float validPlane[3])
{
    char playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));
    LogMessage("Player %s got stuck. Velocity: %.2f %.2f %.2f, Origin: %.2f %.2f %.2f, ValidPlane: %.2f %.2f %.2f",
        playerName,
        velocity[0], velocity[1], velocity[2],
        origin[0], origin[1], origin[2],
        validPlane[0], validPlane[1], validPlane[2]);
}

void Config_Init()
{
    g_cvDebugMode = CreateConVar("sm_surftrainer_debug", "0", "Enable debug mode", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPerfectBoardThreshold = CreateConVar("sm_surftrainer_threshold", "2.0", "Threshold for perfect board detection (in units)", FCVAR_NOTIFY, true, 0.0);
    g_cvTraceDistance = CreateConVar("sm_surftrainer_tracedistance", "64.0", "Distance to trace for ramp detection", FCVAR_NOTIFY, true, 1.0);
    g_cvMaxSurfaceNormalZ = CreateConVar("sm_surftrainer_maxsurfacenormalz", "0.7", "Maximum Z value for surface normal to be considered a ramp", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMinSurfaceNormalZ = CreateConVar("sm_surftrainer_minsurfacenormalz", "0.1", "Minimum Z value for surface normal to be considered a ramp", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "surf_trainer");
}

bool Config_IsDebugMode()
{
    return g_cvDebugMode.BoolValue;
}

float Config_GetPerfectBoardThreshold()
{
    return g_cvPerfectBoardThreshold.FloatValue;
}

float Config_GetTraceDistance()
{
    return g_cvTraceDistance.FloatValue;
}

float Config_GetMaxSurfaceNormalZ()
{
    return g_cvMaxSurfaceNormalZ.FloatValue;
}

float Config_GetMinSurfaceNormalZ()
{
    return g_cvMinSurfaceNormalZ.FloatValue;
}

void Config_LoadMapConfig(const char[] mapName)
{
    char configPath[PLATFORM_MAX_PATH];
    Format(configPath, sizeof(configPath), "configs/surf_trainer/maps/%s.cfg", mapName);
    
    if (FileExists(configPath))
    {
        ServerCommand("exec %s", configPath);
        LogMessage("Loaded map-specific configuration: %s", configPath);
    }
}

void Config_Cleanup()
{
    // might add cleanup here later
}

// HUD
void UI_Init()
{
    g_hHudSync = CreateHudSynchronizer();
}

void UI_DisplayBoardAnalysis(int client, const char[] overallFeedback, float efficiency)
{
    if (g_hHudSync == null || client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    int color1[4], color2[4] = {0, 0, 0, 0};
    if (efficiency >= 90.0)
    {
        color1 = {0, 255, 0, 255};
    }
    else if (efficiency >= 70.0)
    {
        color1 = {255, 255, 0, 255};
    }
    else
    {
        color1 = {255, 0, 0, 255};
    }

    SetHudTextParamsEx(-1.0, 0.25, 5.0, color1, color2, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_hHudSync, overallFeedback);

    // also print to chat for debugging
    PrintToChat(client, "\x01[Surf Trainer] %s", overallFeedback);
}

void UI_DisplaySurfStats(int client)
{
    float avgEfficiency = Stats_GetAverageEfficiency(client);
    int totalBoards = Stats_GetTotalBoards(client);
    float bestEfficiency = Stats_GetBestEfficiency(client);
    float avgSpeed = Stats_GetAverageSpeed(client);
    float totalAirTime = Stats_GetTotalAirTime(client);

    char formattedAvgEfficiency[32], formattedBestEfficiency[32], formattedAvgSpeed[32];
    
    FormatEfficiencyWithColor(avgEfficiency, formattedAvgEfficiency, sizeof(formattedAvgEfficiency));
    FormatEfficiencyWithColor(bestEfficiency, formattedBestEfficiency, sizeof(formattedBestEfficiency));
    Format(formattedAvgSpeed, sizeof(formattedAvgSpeed), "%.2f", avgSpeed);

    int color1[4] = {255, 255, 255, 255};
    int color2[4] = {0, 0, 0, 0};

    SetHudTextParamsEx(-1.0, 0.1, 10.0, color1, color2, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_hHudSync, "%T", "SurfStats", client, formattedAvgEfficiency, totalBoards, formattedBestEfficiency, formattedAvgSpeed, totalAirTime);
}

void UI_NotifyPlayerStuck(int client)
{
    PrintToChat(client, "%T", "PlayerStuck", client);
}

void UI_OpenSettingsMenu(int client)
{
    Menu menu = new Menu(SettingsMenuHandler);
    menu.SetTitle("%T", "SettingsMenuTitle", client);

    char buffer[128];
    Format(buffer, sizeof(buffer), "%T", "ToggleDebugMode", client);
    menu.AddItem("debug", buffer);

    Format(buffer, sizeof(buffer), "%T", "AdjustPerfectThreshold", client);
    menu.AddItem("threshold", buffer);

    Format(buffer, sizeof(buffer), "%T", "ChangeHUDColor", client);
    menu.AddItem("color", buffer);

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int SettingsMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));

            if (StrEqual(info, "debug"))
            {
                ToggleDebugMode(param1);
            }
            else if (StrEqual(info, "threshold"))
            {
                OpenThresholdMenu(param1);
            }
            else if (StrEqual(info, "color"))
            {
                OpenColorMenu(param1);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

void ToggleDebugMode(int client)
{
    bool currentMode = Config_IsDebugMode();
    g_cvDebugMode.SetBool(!currentMode);
    PrintToChat(client, "%T", "DebugModeToggled", client, !currentMode ? "enabled" : "disabled");
    UI_OpenSettingsMenu(client);
}

void OpenThresholdMenu(int client)
{
    Menu menu = new Menu(ThresholdMenuHandler);
    menu.SetTitle("%T", "AdjustPerfectThresholdTitle", client);

    char buffer[128];
    for (float threshold = 1.0; threshold <= 5.0; threshold += 0.5)
    {
        Format(buffer, sizeof(buffer), "%.1f", threshold);
        menu.AddItem(buffer, buffer);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int ThresholdMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            float newThreshold = StringToFloat(info);
            g_cvPerfectBoardThreshold.SetFloat(newThreshold);
            PrintToChat(param1, "%T", "ThresholdUpdated", param1, newThreshold);
            UI_OpenSettingsMenu(param1);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                UI_OpenSettingsMenu(param1);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

void OpenColorMenu(int client)
{
    Menu menu = new Menu(ColorMenuHandler);
    menu.SetTitle("%T", "ChangeHUDColorTitle", client);

    char buffer[128];
    Format(buffer, sizeof(buffer), "%T", "ColorGreen", client);
    menu.AddItem("green", buffer);

    Format(buffer, sizeof(buffer), "%T", "ColorYellow", client);
    menu.AddItem("yellow", buffer);

    Format(buffer, sizeof(buffer), "%T", "ColorRed", client);
    menu.AddItem("red", buffer);

    Format(buffer, sizeof(buffer), "%T", "ColorBlue", client);
    menu.AddItem("blue", buffer);

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int ColorMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            // implement Config_SetHUDColor if needed
            PrintToChat(param1, "%T", "HUDColorUpdated", param1, info);
            UI_OpenSettingsMenu(param1);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                UI_OpenSettingsMenu(param1);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

void FormatEfficiencyWithColor(float efficiency, char[] buffer, int bufferSize)
{
    char colorCode[16];
    if (efficiency >= 90.0)
    {
        strcopy(colorCode, sizeof(colorCode), "\x04");
    }
    else if (efficiency >= 70.0)
    {
        strcopy(colorCode, sizeof(colorCode), "\x09");
    }
    else
    {
        strcopy(colorCode, sizeof(colorCode), "\x02");
    }
    
    Format(buffer, bufferSize, "%s%.2f%%\x01", colorCode, efficiency);
}

void UI_Cleanup()
{
    if (g_hHudSync != null)
    {
        CloseHandle(g_hHudSync);
        g_hHudSync = null;
    }
}

// visualization Module
void Visualization_Init()
{
    // initialize anything here in the future
}

void Visualization_PrecacheAssets()
{
    g_iBeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
}

void Visualization_Cleanup()
{
    // cleanup here
}

// stats
void Stats_Init()
{
    // same thing
}

void Stats_ResetClientState(int client)
{
    g_flLastProcessTime[client] = 0.0;
    g_bTouchingRamp[client] = false;
    g_bJustStartedTouchingRamp[client] = false;
    ZeroVector(g_vPreBoardVelocity[client]);
    ZeroVector(g_vLastBumpVelocity[client]);
    ZeroVector(g_vLastBumpOrigin[client]);
    g_iBoardEfficiencyIndex[client] = 0;
    g_flAverageSpeed[client] = 0.0;
    g_flTotalAirTime[client] = 0.0;
    g_flLastGroundTime[client] = GetGameTime();
    g_iTotalBoards[client] = 0;
    
    for (int i = 0; i < MAX_STATS_ENTRIES; i++)
    {
        g_flBoardEfficiencies[client][i] = 0.0;
    }
}

void Stats_SaveClientStats(int client)
{
    // implement sqlite or mysql support later
}

float Stats_GetLastProcessTime(int client)
{
    return g_flLastProcessTime[client];
}

void Stats_SetLastProcessTime(int client, float time)
{
    g_flLastProcessTime[client] = time;
}

bool Stats_IsTouchingRamp(int client)
{
    return g_bTouchingRamp[client];
}

void Stats_SetTouchingRamp(int client, bool touching)
{
    g_bTouchingRamp[client] = touching;
}

bool Stats_IsJustStartedTouchingRamp(int client)
{
    return g_bJustStartedTouchingRamp[client];
}

void Stats_SetJustStartedTouchingRamp(int client, bool justStarted)
{
    g_bJustStartedTouchingRamp[client] = justStarted;
}

void Stats_SetPreBoardVelocity(int client, const float velocity[3])
{
    CopyVector(velocity, g_vPreBoardVelocity[client]);
}

void Stats_StoreEfficiency(int client, float efficiency)
{
    g_flBoardEfficiencies[client][g_iBoardEfficiencyIndex[client]] = efficiency;
    g_iBoardEfficiencyIndex[client] = (g_iBoardEfficiencyIndex[client] + 1) % MAX_STATS_ENTRIES;
    g_iTotalBoards[client]++;
}

void Stats_UpdateAverageSpeed(int client, float speed)
{
    g_flAverageSpeed[client] = (g_flAverageSpeed[client] * (g_iTotalBoards[client] - 1) + speed) / g_iTotalBoards[client];
}

void Stats_UpdateAirTime(int client, float airTime)
{
    g_flTotalAirTime[client] += airTime;
    g_flLastGroundTime[client] = GetGameTime();
}

float Stats_GetLastGroundTime(int client)
{
    return g_flLastGroundTime[client];
}

float Stats_GetAverageEfficiency(int client)
{
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++)
    {
        if (g_flBoardEfficiencies[client][i] != 0.0)
        {
            total += g_flBoardEfficiencies[client][i];
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

int Stats_GetTotalBoards(int client)
{
    return g_iTotalBoards[client];
}

float Stats_GetBestEfficiency(int client)
{
    float best = 0.0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++)
    {
        if (g_flBoardEfficiencies[client][i] > best)
        {
            best = g_flBoardEfficiencies[client][i];
        }
    }
    return best;
}

float Stats_GetAverageSpeed(int client)
{
    return g_flAverageSpeed[client];
}

float Stats_GetTotalAirTime(int client)
{
    return g_flTotalAirTime[client];
}

void Stats_ResetMapStats()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Stats_ResetClientState(i);
        }
    }
}

void Stats_Cleanup()
{
    // cleanup
}

// utility 
void ZeroVector(float vec[3])
{
    vec[0] = vec[1] = vec[2] = 0.0;
}

void CopyVector(const float src[3], float dest[3])
{
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}
