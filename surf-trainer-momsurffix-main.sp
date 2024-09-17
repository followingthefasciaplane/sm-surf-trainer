#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "4.2"
#define MAX_RAMPS 100
#define MAX_TRAJECTORY_POINTS 1000

enum struct RampStats
{
    float entrySpeed;
    float exitSpeed;
    float entryAngle;
    float exitAngle;
    float rampAngle;
    float rampTime;
    int clipCount;
    float maxSpeed;
    float averageSpeed;
    float efficiency;
    float optimalExitAngle;
    float speedGained;
    float theoreticalMaxExitSpeed;
}

enum struct PlayerStats
{
    int currentRamp;
    float totalAirTime;
    bool onRamp;
    float rampEntryTime;
    float lastClipTime;
    bool trainingMode;
    float currentVelocity[3];
    float currentNormal[3];
    float lastOrigin[3];
    int airAccelCount;
    float airAccelEfficiency;
    float airAccelGain;
    Handle trajectory;
    Handle rampStats;
}

// Globals
ConVar g_cvDebugMode;
PlayerStats g_PlayerStats[MAXPLAYERS + 1];
Handle g_hHudSync;
bool g_PluginReady = false;
int g_iLaserBeamIndex;

public void OnPluginStart()
{
    CreateConVar("sm_surftrainer_version", PLUGIN_VERSION, "Surf trainer version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvDebugMode = CreateConVar("sm_surftrainer_debug", "0", "Enable debug mode", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hHudSync = CreateHudSynchronizer();
    if (g_hHudSync == INVALID_HANDLE)
    {
        LogError("Failed to create HUD synchronizer.");
    }

    RegConsoleCmd("sm_surfstats", Command_SurfStats, "Display surf statistics");
    RegConsoleCmd("sm_trajvis", Command_VisualizeTrajectory, "Visualize recent trajectory");
    RegConsoleCmd("sm_train", Command_ToggleTraining, "Toggle surf training mode");

    HookEvent("player_spawn", Event_PlayerSpawn);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_PlayerStats[i].trajectory = INVALID_HANDLE;
        g_PlayerStats[i].rampStats = INVALID_HANDLE;
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }

    g_PluginReady = true;
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
}

public void OnClientDisconnect(int client)
{
    ClearClientData(client);
}

void ResetClientState(int client)
{
    g_PlayerStats[client].currentRamp = 0;
    g_PlayerStats[client].totalAirTime = 0.0;
    g_PlayerStats[client].onRamp = false;
    g_PlayerStats[client].rampEntryTime = 0.0;
    g_PlayerStats[client].lastClipTime = 0.0;
    g_PlayerStats[client].airAccelCount = 0;
    g_PlayerStats[client].airAccelEfficiency = 0.0;
    g_PlayerStats[client].airAccelGain = 0.0;
    g_PlayerStats[client].trainingMode = false;

    for (int i = 0; i < 3; i++)
    {
        g_PlayerStats[client].currentVelocity[i] = 0.0;
        g_PlayerStats[client].currentNormal[i] = 0.0;
        g_PlayerStats[client].lastOrigin[i] = 0.0;
    }

    if (g_PlayerStats[client].trajectory == INVALID_HANDLE)
    {
        g_PlayerStats[client].trajectory = CreateArray(7);
    }
    else
    {
        ClearArray(g_PlayerStats[client].trajectory);
    }

    if (g_PlayerStats[client].rampStats == INVALID_HANDLE)
    {
        g_PlayerStats[client].rampStats = CreateArray(13);
    }
    else
    {
        ClearArray(g_PlayerStats[client].rampStats);
    }
}

void ClearClientData(int client)
{
    if (g_PlayerStats[client].trajectory != INVALID_HANDLE)
    {
        CloseHandle(g_PlayerStats[client].trajectory);
        g_PlayerStats[client].trajectory = INVALID_HANDLE;
    }
    if (g_PlayerStats[client].rampStats != INVALID_HANDLE)
    {
        CloseHandle(g_PlayerStats[client].rampStats);
        g_PlayerStats[client].rampStats = INVALID_HANDLE;
    }
}

bool IsOnRamp(const float normal[3], const float velocity[3])
{
    // Check if the surface normal is steep enough (Z component less than 0.7)
    if (normal[2] >= 0.7)
    {
        return false;
    }

    // Check if the player is moving along the surface
    float dotProduct = FloatAbs(GetVectorDotProduct(normal, velocity));
    return (dotProduct < 0.1);
}

void UpdateRampDetection(int client, const float normal[3], const float velocity[3], const float origin[3])
{
    bool wasOnRamp = g_PlayerStats[client].onRamp;
    bool isOnRamp = IsOnRamp(normal, velocity);

    if (!wasOnRamp && isOnRamp)
    {
        // Player just entered a ramp
        StartNewRamp(client, velocity, normal, origin);
    }
    else if (wasOnRamp && !isOnRamp)
    {
        // Player just left a ramp
        EndCurrentRamp(client, velocity);
    }

    g_PlayerStats[client].onRamp = isOnRamp;
}

void StartNewRamp(int client, const float velocity[3], const float normal[3], const float origin[3])
{
    g_PlayerStats[client].rampEntryTime = GetGameTime();

    RampStats newRamp;
    newRamp.entrySpeed = GetVectorLength(velocity);
    newRamp.exitSpeed = 0.0;
    newRamp.entryAngle = CalculateAngleWithSurface(velocity, normal);
    newRamp.exitAngle = 0.0;
    newRamp.rampAngle = RadToDeg(ACos(Clamp(normal[2], -1.0, 1.0)));
    newRamp.rampTime = 0.0;
    newRamp.clipCount = 0;
    newRamp.maxSpeed = newRamp.entrySpeed;
    newRamp.averageSpeed = newRamp.entrySpeed;
    newRamp.efficiency = 0.0;
    newRamp.optimalExitAngle = 0.0;
    newRamp.speedGained = 0.0;
    newRamp.theoreticalMaxExitSpeed = 0.0;

    int rampIndex = GetArraySize(g_PlayerStats[client].rampStats) / 13;
    StoreRampStats(g_PlayerStats[client].rampStats, rampIndex, newRamp);
    g_PlayerStats[client].currentRamp = rampIndex;

    VectorCopy(origin, g_PlayerStats[client].lastOrigin);
}

void EndCurrentRamp(int client, const float exitVelocity[3])
{
    int currentRamp = g_PlayerStats[client].currentRamp;
    RampStats rampData;
    RetrieveRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);

    rampData.exitSpeed = GetVectorLength(exitVelocity);
    rampData.exitAngle = CalculateAngleWithSurface(exitVelocity, g_PlayerStats[client].currentNormal);
    rampData.rampTime = GetGameTime() - g_PlayerStats[client].rampEntryTime;
    rampData.speedGained = rampData.exitSpeed - rampData.entrySpeed;

    CalculateRampEfficiency(rampData);

    StoreRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);
}

void CalculateRampEfficiency(RampStats rampData)
{
    // Calculate theoretical maximum exit speed
    float gravity = GetCurrentGravity();
    float frameTime = GetGameFrameTime();
    rampData.theoreticalMaxExitSpeed = rampData.entrySpeed * SquareRoot(1.0 + 2.0 * frameTime * gravity * Sin(DegToRad(rampData.rampAngle)));

    // Calculate optimal exit angle
    rampData.optimalExitAngle = rampData.rampAngle;

    // Angle efficiency
    float angleEfficiency = 1.0 - (FloatAbs(rampData.exitAngle - rampData.optimalExitAngle) / 90.0);

    // Speed efficiency
    float speedEfficiency = (rampData.exitSpeed - rampData.entrySpeed) / (rampData.theoreticalMaxExitSpeed - rampData.entrySpeed);
    speedEfficiency = Clamp(speedEfficiency, 0.0, 1.0);

    // Combined efficiency
    rampData.efficiency = (angleEfficiency + speedEfficiency) / 2.0;
}

void AnalyzeAirAccel(int client, const float newVelocity[3], float frameTime)
{
    float oldVelocity[3];
    VectorCopy(g_PlayerStats[client].currentVelocity, oldVelocity);

    float oldSpeed = GetVectorLength(oldVelocity);
    float newSpeed = GetVectorLength(newVelocity);

    if (newSpeed > oldSpeed)
    {
        g_PlayerStats[client].airAccelCount++;

        // Calculate acceleration
        float acceleration[3];
        SubtractVectors(newVelocity, oldVelocity, acceleration);
        ScaleVector(acceleration, 1.0 / frameTime);

        // Calculate efficiency based on the angle between velocity and acceleration
        float accelMag = GetVectorLength(acceleration);
        if (accelMag != 0.0 && oldSpeed != 0.0)
        {
            float dotProduct = GetVectorDotProduct(oldVelocity, acceleration);
            float efficiency = dotProduct / (oldSpeed * accelMag);

            g_PlayerStats[client].airAccelEfficiency += efficiency;
            g_PlayerStats[client].airAccelGain += newSpeed - oldSpeed;
        }
    }
}

public Action MomSurfFix_OnBumpIteration(int client, int bumpcount, float velocity[3], float origin[3])
{
    if (!g_PluginReady || !IsValidClient(client)) return Plugin_Continue;

    UpdateRampDetection(client, g_PlayerStats[client].currentNormal, velocity, origin);

    // Update current velocity and origin
    VectorCopy(velocity, g_PlayerStats[client].currentVelocity);
    VectorCopy(origin, g_PlayerStats[client].lastOrigin);

    // Add to trajectory
    float data[7];
    for (int i = 0; i < 3; i++)
    {
        data[i] = origin[i];
        data[i + 3] = velocity[i];
    }
    data[6] = GetGameTime();

    PushArrayArray(g_PlayerStats[client].trajectory, data, sizeof(data));

    if (GetArraySize(g_PlayerStats[client].trajectory) > MAX_TRAJECTORY_POINTS)
    {
        RemoveFromArray(g_PlayerStats[client].trajectory, 0);
    }

    return Plugin_Continue;
}

public Action MomSurfFix_OnClipVelocity(int client, float inVelocity[3], float normal[3], float &overbounce)
{
    if (!g_PluginReady || !IsValidClient(client)) return Plugin_Continue;

    // Store the current normal for angle calculations
    VectorCopy(normal, g_PlayerStats[client].currentNormal);

    if (g_PlayerStats[client].onRamp)
    {
        int currentRamp = g_PlayerStats[client].currentRamp;
        RampStats rampData;
        RetrieveRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);
        rampData.clipCount++;
        StoreRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);
    }

    g_PlayerStats[client].lastClipTime = GetGameTime();

    return Plugin_Continue;
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int blocked, float endVelocity[3], float endOrigin[3], float allFraction)
{
    if (!g_PluginReady || !IsValidClient(client)) return;

    float frameTime = GetGameTime() - g_PlayerStats[client].lastClipTime;

    if (g_PlayerStats[client].onRamp)
    {
        int currentRamp = g_PlayerStats[client].currentRamp;
        RampStats rampData;
        RetrieveRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);

        float speedAfter = GetVectorLength(endVelocity);
        if (speedAfter > rampData.maxSpeed)
        {
            rampData.maxSpeed = speedAfter;
        }
        rampData.averageSpeed = (rampData.averageSpeed * rampData.clipCount + speedAfter) / (rampData.clipCount + 1);

        StoreRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);
    }
    else
    {
        // Player is in the air
        g_PlayerStats[client].totalAirTime += frameTime;
        AnalyzeAirAccel(client, endVelocity, frameTime);
    }

    // Update current velocity
    VectorCopy(endVelocity, g_PlayerStats[client].currentVelocity);

    float data[7];
    for (int i = 0; i < 3; i++)
    {
        data[i] = endOrigin[i];
        data[i + 3] = endVelocity[i];
    }
    data[6] = GetGameTime();

    PushArrayArray(g_PlayerStats[client].trajectory, data, sizeof(data));

    if (GetArraySize(g_PlayerStats[client].trajectory) > MAX_TRAJECTORY_POINTS)
    {
        RemoveFromArray(g_PlayerStats[client].trajectory, 0);
    }

    UpdateRampDetection(client, g_PlayerStats[client].currentNormal, endVelocity, endOrigin);
}

float CalculateAngleWithSurface(const float velocity[3], const float normal[3])
{
    float normalizedVelocity[3];
    NormalizeVector(velocity, normalizedVelocity);
    float dot = GetVectorDotProduct(normalizedVelocity, normal);
    dot = Clamp(dot, -1.0, 1.0);
    return RadToDeg(ACos(dot));
}

void VectorCopy(const float src[3], float dest[3])
{
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client));
}

public Action Command_SurfStats(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    DisplaySurfStats(client);
    return Plugin_Handled;
}

void ProvideFeedback(int client)
{
    if (!g_PlayerStats[client].onRamp)
    {
        AnalyzeAirMovement(client);
    }
    else
    {
        AnalyzeRampMovement(client);
    }
}

void AnalyzeAirMovement(int client)
{
    if (g_PlayerStats[client].airAccelCount == 0) return;

    float averageEfficiency = g_PlayerStats[client].airAccelEfficiency / float(g_PlayerStats[client].airAccelCount);
    float averageGain = g_PlayerStats[client].airAccelGain / float(g_PlayerStats[client].airAccelCount);

    char feedback[256];
    if (averageEfficiency < 0.5)
    {
        Format(feedback, sizeof(feedback), "Try to accelerate more in the direction of your movement for better air control.");
    }
    else if (averageGain < 1.0)
    {
        Format(feedback, sizeof(feedback), "You're maintaining speed well, but try to gain more speed in the air.");
    }
    else
    {
        Format(feedback, sizeof(feedback), "Good air control! Keep it up!");
    }

    PrintToChat(client, "[Surf Trainer] Air Movement: %s", feedback);
}

void AnalyzeRampMovement(int client)
{
    int currentRamp = g_PlayerStats[client].currentRamp;
    RampStats rampData;
    RetrieveRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);

    char feedback[256];
    if (rampData.efficiency < 0.6)
    {
        Format(feedback, sizeof(feedback), "Try to enter the ramp at a better angle and aim for an exit angle of %.1f degrees.", rampData.optimalExitAngle);
    }
    else if (rampData.exitSpeed < rampData.theoreticalMaxExitSpeed * 0.8)
    {
        Format(feedback, sizeof(feedback), "Good angle, but try to conserve more speed. Aim for an exit speed closer to %.1f.", rampData.theoreticalMaxExitSpeed);
    }
    else
    {
        Format(feedback, sizeof(feedback), "Excellent ramp navigation! Your efficiency is %.1f%%", rampData.efficiency * 100.0);
    }

    PrintToChat(client, "[Surf Trainer] Ramp Movement: %s", feedback);
}

public Action Command_ToggleTraining(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    g_PlayerStats[client].trainingMode = !g_PlayerStats[client].trainingMode;
    PrintToChat(client, "[Surf Trainer] Training mode %s.", g_PlayerStats[client].trainingMode ? "enabled" : "disabled");

    return Plugin_Handled;
}

public void OnGameFrame()
{
    if (!g_PluginReady) return;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client) && g_PlayerStats[client].trainingMode)
        {
            ProvideFeedback(client);
            UpdatePlayerHUD(client);
        }
    }
}

void DisplaySurfStats(int client)
{
    int totalRamps = GetArraySize(g_PlayerStats[client].rampStats) / 13;
    float totalEfficiency = 0.0;
    float bestEfficiency = 0.0;
    float totalSpeedGain = 0.0;

    for (int i = 0; i < totalRamps; i++)
    {
        RampStats rampData;
        RetrieveRampStats(g_PlayerStats[client].rampStats, i, rampData);

        totalEfficiency += rampData.efficiency;
        if (rampData.efficiency > bestEfficiency)
        {
            bestEfficiency = rampData.efficiency;
        }
        totalSpeedGain += rampData.speedGained;
    }

    float averageEfficiency = (totalRamps > 0) ? (totalEfficiency / float(totalRamps)) : 0.0;
    float averageSpeedGain = (totalRamps > 0) ? (totalSpeedGain / float(totalRamps)) : 0.0;
    float averageAirAccelEfficiency = (g_PlayerStats[client].airAccelCount > 0) ?
        (g_PlayerStats[client].airAccelEfficiency / float(g_PlayerStats[client].airAccelCount)) : 0.0;

    char statsMessage[512];
    Format(statsMessage, sizeof(statsMessage),
        "Surf Statistics:\n",
        "Total Ramps: %d\n",
        "Average Efficiency: %.2f%%\n",
        "Best Efficiency: %.2f%%\n",
        "Average Speed Gain: %.2f\n",
        "Total Air Accelerations: %d\n",
        "Air Accel Efficiency: %.2f%%\n",
        "Total Air Time: %.2f seconds",
        totalRamps,
        averageEfficiency * 100.0,
        bestEfficiency * 100.0,
        averageSpeedGain,
        g_PlayerStats[client].airAccelCount,
        averageAirAccelEfficiency * 100.0,
        g_PlayerStats[client].totalAirTime
    );

    PrintToChat(client, "[Surf Trainer] Statistics have been printed to your console.");
    PrintToConsole(client, "%s", statsMessage);
}

public Action Command_VisualizeTrajectory(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    VisualizeTrajectory(client);
    PrintToChat(client, "[Surf Trainer] Trajectory visualization sent.");
    return Plugin_Handled;
}

void VisualizeTrajectory(int client)
{
    if (g_PlayerStats[client].trajectory == INVALID_HANDLE || GetArraySize(g_PlayerStats[client].trajectory) < 2) return;

    float prevPoint[7], currentPoint[7];
    GetArrayArray(g_PlayerStats[client].trajectory, 0, prevPoint, sizeof(prevPoint));

    for (int i = 1; i < GetArraySize(g_PlayerStats[client].trajectory); i++)
    {
        GetArrayArray(g_PlayerStats[client].trajectory, i, currentPoint, sizeof(currentPoint));

        int color[4];
        if (IsPointOnRamp(client, currentPoint))
        {
            color[0] = 0; color[1] = 255; color[2] = 0; color[3] = 255; // Green for on ramp
        }
        else
        {
            color[0] = 255; color[1] = 0; color[2] = 0; color[3] = 255; // Red for in air
        }

        float prevPos[3], currentPos[3];
        for (int j = 0; j < 3; j++)
        {
            prevPos[j] = prevPoint[j];
            currentPos[j] = currentPoint[j];
        }
        TE_SetupBeamPoints(prevPos, currentPos, g_iLaserBeamIndex, 0, 0, 0, 0.1, 1.0, 1.0, 1, 0.0, color, 0);
        TE_SendToClient(client);

        // Copy current point to prev point for next iteration
        for (int j = 0; j < 7; j++)
        {
            prevPoint[j] = currentPoint[j];
        }
    }
}

bool IsPointOnRamp(int client, const float point[7])
{
    // Extract velocity from the point data
    float velocity[3];
    velocity[0] = point[3];
    velocity[1] = point[4];
    velocity[2] = point[5];

    // Use the IsOnRamp function
    return IsOnRamp(g_PlayerStats[client].currentNormal, velocity);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client))
    {
        ResetClientState(client);
    }
}

void UpdatePlayerHUD(int client)
{
    if (!g_cvDebugMode.BoolValue) return;

    int currentRamp = g_PlayerStats[client].currentRamp;
    RampStats rampData;
    if (GetArraySize(g_PlayerStats[client].rampStats) / 13 > currentRamp)
    {
        RetrieveRampStats(g_PlayerStats[client].rampStats, currentRamp, rampData);
    }
    else
    {
        return; // No ramp data available
    }

    char hudText[256];
    Format(hudText, sizeof(hudText),
        "Current Ramp: %d\n",
        "Speed: %.2f\n",
        "Efficiency: %.2f%%\n",
        "Clip Count: %d\n",
        "Air Accels: %d\n",
        "Air Time: %.2f",
        currentRamp + 1,
        GetVectorLength(g_PlayerStats[client].currentVelocity),
        rampData.efficiency * 100.0,
        rampData.clipCount,
        g_PlayerStats[client].airAccelCount,
        g_PlayerStats[client].totalAirTime
    );

    SetHudTextParams(0.7, 0.1, 0.1, 255, 255, 255, 255);
    ShowSyncHudText(client, g_hHudSync, hudText);
}

public void OnMapStart()
{
    g_iLaserBeamIndex = PrecacheModel("materials/sprites/laserbeam.vmt");
}

public void OnPluginEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            ClearClientData(i);
        }
    }

    if (g_hHudSync != INVALID_HANDLE)
    {
        CloseHandle(g_hHudSync);
        g_hHudSync = INVALID_HANDLE;
    }
}

float GetCurrentGravity()
{
    static Handle hGravityConVar = INVALID_HANDLE;
    if (hGravityConVar == INVALID_HANDLE)
    {
        hGravityConVar = FindConVar("sv_gravity");
    }
    return GetConVarFloat(hGravityConVar);
}

float Sin(float radians)
{
    return Sine(radians);
}

float ACos(float value)
{
    return ArcCosine(value);
}

float Clamp(float value, float min, float max)
{
    if (value < min)
        return min;
    else if (value > max)
        return max;
    else
        return value;
}

// Functions for storing and retrieving RampStats
void StoreRampStats(Handle hArray, int index, RampStats stats)
{
    float data[13];
    data[0] = stats.entrySpeed;
    data[1] = stats.exitSpeed;
    data[2] = stats.entryAngle;
    data[3] = stats.exitAngle;
    data[4] = stats.rampAngle;
    data[5] = stats.rampTime;
    data[6] = float(stats.clipCount);
    data[7] = stats.maxSpeed;
    data[8] = stats.averageSpeed;
    data[9] = stats.efficiency;
    data[10] = stats.optimalExitAngle;
    data[11] = stats.speedGained;
    data[12] = stats.theoreticalMaxExitSpeed;

    if (index * 13 >= GetArraySize(hArray))
    {
        for (int i = 0; i < 13; i++)
        {
            PushArrayCell(hArray, data[i]);
        }
    }
    else
    {
        for (int i = 0; i < 13; i++)
        {
            SetArrayCell(hArray, index * 13 + i, data[i]);
        }
    }
}

void RetrieveRampStats(Handle hArray, int index, RampStats stats)
{
    float data[13];
    for (int i = 0; i < 13; i++)
    {
        data[i] = GetArrayCell(hArray, index * 13 + i);
    }
    stats.entrySpeed = data[0];
    stats.exitSpeed = data[1];
    stats.entryAngle = data[2];
    stats.exitAngle = data[3];
    stats.rampAngle = data[4];
    stats.rampTime = data[5];
    stats.clipCount = RoundToZero(data[6]);
    stats.maxSpeed = data[7];
    stats.averageSpeed = data[8];
    stats.efficiency = data[9];
    stats.optimalExitAngle = data[10];
    stats.speedGained = data[11];
    stats.theoreticalMaxExitSpeed = data[12];
}
