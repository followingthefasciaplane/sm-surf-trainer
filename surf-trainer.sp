//wip

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.3"
#define EPSILON 0.00001
#define TRACE_DISTANCE 64.0
#define MAX_SURFACE_NORMAL_Z 0.7
#define MIN_SURFACE_NORMAL_Z 0.1
#define MAX_PREDICTION_POINTS 10
#define MAX_WISH_SPEED 30.0
#define MAX_STATS_ENTRIES 100

ConVar g_cvAirAccelerate;
ConVar g_cvMaxVelocity;
ConVar g_cvGravity;
ConVar g_cvDebugMode;
ConVar g_cvPerfectBoardThreshold;

bool g_bDebugMode;
float g_flTickInterval;
float g_flPerfectBoardThreshold;
Handle g_hCheckClientsTimer = INVALID_HANDLE;
Handle g_hHudSync;

// player-specific variables
float g_vVelocity[MAXPLAYERS + 1][3];
float g_vOrigin[MAXPLAYERS + 1][3];
bool g_bTouchingRamp[MAXPLAYERS + 1];
bool g_bJustStartedTouchingRamp[MAXPLAYERS + 1];
float g_vPreBoardVelocity[MAXPLAYERS + 1][3];
float g_flLastProcessTime[MAXPLAYERS + 1];
float g_flBoardEfficiencies[MAXPLAYERS + 1][MAX_STATS_ENTRIES];
int g_iBoardEfficiencyIndex[MAXPLAYERS + 1];

public Plugin myinfo = {
    name = "Surf Trainer",
    author = "Is it Your Name? Or is it My Name?",
    description = "A plugin to help players improve their surfing skills",
    version = PLUGIN_VERSION,
    url = "http://www.sourcemod.net/"
};

public void OnPluginStart() {
    CreateConVar("sm_surftrainer_version", PLUGIN_VERSION, "Surf trainer version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
    g_cvAirAccelerate = FindConVar("sv_airaccelerate");
    g_cvMaxVelocity = FindConVar("sv_maxvelocity");
    g_cvGravity = FindConVar("sv_gravity");
    g_cvDebugMode = CreateConVar("sm_surftrainer_debug", "0", "Enable debug mode", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPerfectBoardThreshold = CreateConVar("sm_surftrainer_threshold", "2.0", "Threshold for perfect board detection (in units)", FCVAR_NOTIFY, true, 0.0);

    RegConsoleCmd("sm_surfstats", Command_SurfStats, "Display surf statistics");

    g_bDebugMode = g_cvDebugMode.BoolValue;
    g_flTickInterval = GetTickInterval();
    g_flPerfectBoardThreshold = g_cvPerfectBoardThreshold.FloatValue;

    HookEvent("player_spawn", Event_PlayerSpawn);
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }

    g_hHudSync = CreateHudSynchronizer();

    AutoExecConfig(true, "surf-trainer");
} 

public void OnClientPutInServer(int client) {
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    ResetClientState(client);
}

public void OnClientDisconnect(int client) {
    SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    ResetClientState(client);
}

void ResetClientState(int client) {
    g_bTouchingRamp[client] = false;
    g_bJustStartedTouchingRamp[client] = false;
    ZeroVector(g_vVelocity[client]);
    ZeroVector(g_vOrigin[client]);
    ZeroVector(g_vPreBoardVelocity[client]);
    g_iBoardEfficiencyIndex[client] = 0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        g_flBoardEfficiencies[client][i] = 0.0;
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        ResetClientState(client);
    }
}

public void OnPostThinkPost(int client)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        return;
    }

    float currentTime = GetGameTime();
    if (currentTime - g_flLastProcessTime[client] < g_flTickInterval)
    {
        return;
    }

    g_flLastProcessTime[client] = currentTime;

    SimulatePlayerMovement(client);
}

void PhysicsSimulate(int client, float vOutVelocity[3], float vOutOrigin[3]) {
    float vWishDir[3], vWishVel[3];
    float flWishSpeed;
    
    // Copy the current velocity to g_vVelocity for simulation
    CopyVector(vOutVelocity, g_vVelocity[client]);
    
    StartGravity(client);
    AirMove(client, vWishDir, vWishVel, flWishSpeed);
    FinishGravity(client);
    
    TryPlayerMove(client, vOutOrigin);
    
    // Final velocity check
    CheckVelocity(client);
    
    // Copy the simulated velocity back to vOutVelocity
    CopyVector(g_vVelocity[client], vOutVelocity);
}

void SimulatePlayerMovement(int client)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        return;
    }

    // Get current player position and velocity
    if (!GetClientAbsOrigin(client, g_vOrigin[client])) {
        LogError("Failed to get client origin for client %d", client);
        return;
    }
    
    if (!GetEntPropVector(client, Prop_Data, "m_vecVelocity", g_vVelocity[client])) {
        LogError("Failed to get client velocity for client %d", client);
        return;
    }

    float surfaceNormal[3];
    bool isOnSurfRamp = IsPlayerOnSurfRamp(client, surfaceNormal);

    // Handle ramp touch logic
    if (isOnSurfRamp) {
        if (!g_bTouchingRamp[client]) {
            g_bTouchingRamp[client] = true;
            g_bJustStartedTouchingRamp[client] = true;
            CopyVector(g_vVelocity[client], g_vPreBoardVelocity[client]);
        } else if (g_bJustStartedTouchingRamp[client]) {
            AnalyzeBoard(client, surfaceNormal);
            g_bJustStartedTouchingRamp[client] = false;
        }
    } else {
        g_bTouchingRamp[client] = false;
        g_bJustStartedTouchingRamp[client] = false;
    }

    // Simulate physics for next tick
    float vSimulatedVelocity[3], vSimulatedOrigin[3];
    CopyVector(g_vVelocity[client], vSimulatedVelocity);
    CopyVector(g_vOrigin[client], vSimulatedOrigin);
    PhysicsSimulate(client, vSimulatedVelocity, vSimulatedOrigin);

    // Visualize predicted trajectory
    VisualizePredictedTrajectory(client, vSimulatedVelocity);

    if (g_bDebugMode) {
        float xyVelocity[3];
        xyVelocity[0] = vSimulatedVelocity[0];
        xyVelocity[1] = vSimulatedVelocity[1];
        xyVelocity[2] = 0.0;
        float xySpeed = GetVectorLength(xyVelocity);
        PrintToConsole(client, "Predicted XY Velocity: %.2f %.2f | XY Speed: %.2f", 
            xyVelocity[0], xyVelocity[1], xySpeed);
    }
}

void StartGravity(int client) {
    float flGravity = g_cvGravity.FloatValue;
    g_vVelocity[client][2] -= (flGravity * 0.5 * g_flTickInterval);
}

void FinishGravity(int client) {
    float flGravity = g_cvGravity.FloatValue;
    g_vVelocity[client][2] -= (flGravity * 0.5 * g_flTickInterval);
}

void AirMove(int client, float vWishDir[3], float vWishVel[3], float &flWishSpeed)
{
    float vForward[3], vRight[3], vUp[3];
    float vClientAngles[3];
    
    GetClientEyeAngles(client, vClientAngles);
    AngleVectors(vClientAngles, vForward, vRight, vUp);
    
    float flForwardMove = GetEntPropFloat(client, Prop_Data, "m_flForwardMove");
    float flSideMove = GetEntPropFloat(client, Prop_Data, "m_flSideMove");
    
    for (int i = 0; i < 2; i++)
    {
        vWishVel[i] = vForward[i] * flForwardMove + vRight[i] * flSideMove;
    }
    vWishVel[2] = 0.0;
    
    flWishSpeed = GetVectorLength(vWishVel);
    
    // Determine the direction of movement
    if (flWishSpeed != 0.0)
    {
        NormalizeVector(vWishVel, vWishDir);
    }
    else
    {
        for (int i = 0; i < 3; i++)
        {
            vWishDir[i] = 0.0;
        }
    }
    
    // Cap speed
    if (flWishSpeed > MAX_WISH_SPEED)
    {
        ScaleVector(vWishVel, MAX_WISH_SPEED / flWishSpeed);
        flWishSpeed = MAX_WISH_SPEED;
    }
    
    AirAccelerate(client, vWishDir, flWishSpeed, g_cvAirAccelerate.FloatValue);
}

void AirAccelerate(int client, const float vWishDir[3], float flWishSpeed, float flAirAccelerate)
{
    float flCurrentSpeed = GetVectorDotProduct(g_vVelocity[client], vWishDir);
    float flAddSpeed = flWishSpeed - flCurrentSpeed;

    if (flAddSpeed <= 0)
    {
        return;
    }

    float flAccelSpeed = flAirAccelerate * flWishSpeed * g_flTickInterval;

    if (flAccelSpeed > flAddSpeed)
    {
        flAccelSpeed = flAddSpeed;
    }

    for (int i = 0; i < 3; i++)
    {
        g_vVelocity[client][i] += flAccelSpeed * vWishDir[i];
    }
}

void TryPlayerMove(int client, float vOutOrigin[3]) {
    float vOriginalVelocity[3];
    CopyVector(g_vVelocity[client], vOriginalVelocity);
    
    float vClippedVelocity[3];
    float vTotalLeftToMove[3];
    CopyVector(g_vVelocity[client], vTotalLeftToMove);
    float flTimeLeft = g_flTickInterval;
    
    for (int bumpCount = 0; bumpCount < 4; bumpCount++) {
        if (GetVectorLength(vTotalLeftToMove) == 0.0) {
            break;
        }
        
        float vEnd[3];
        for (int i = 0; i < 3; i++) {
            vEnd[i] = vOutOrigin[i] + vTotalLeftToMove[i] * flTimeLeft;
        }
        
        TR_TraceHullFilter(vOutOrigin, vEnd, 
            view_as<float>({-16.0, -16.0, 0.0}), 
            view_as<float>({16.0, 16.0, 72.0}), 
            MASK_PLAYERSOLID, 
            TraceFilter_World, 
            client);
        
        if (TR_DidHit()) {
            float vPlaneNormal[3];
            TR_GetPlaneNormal(null, vPlaneNormal);
            
            ClipVelocity(vTotalLeftToMove, vPlaneNormal, vClippedVelocity, 1.0);
            
            float flDistanceMoved = (flTimeLeft * GetVectorLength(vTotalLeftToMove) - GetVectorLength(vClippedVelocity));
            flTimeLeft -= flTimeLeft * flDistanceMoved / GetVectorLength(vTotalLeftToMove);
            
            CopyVector(vClippedVelocity, vTotalLeftToMove);
        } else {
            CopyVector(vOriginalVelocity, g_vVelocity[client]);
            return;
        }
    }
    
    CopyVector(vClippedVelocity, g_vVelocity[client]);
}

void ClipVelocity(const float vIn[3], const float vNormal[3], float vOut[3], float flOverbounce) {
    float flBackoff = GetVectorDotProduct(vIn, vNormal) * flOverbounce;
    
    float flChange;
    for (int i = 0; i < 3; i++) {
        flChange = vNormal[i] * flBackoff;
        vOut[i] = vIn[i] - flChange;
        
        if (vOut[i] > -EPSILON && vOut[i] < EPSILON) {
            vOut[i] = 0.0;
        }
    }
    
    // Ensure we don't have any leftover velocity in the normal direction
    float flAdjust = GetVectorDotProduct(vOut, vNormal);
    if (flAdjust < 0.0) {
        for (int i = 0; i < 3; i++) {
            vOut[i] -= (vNormal[i] * flAdjust);
        }
    }
}

void CheckVelocity(int client) {
    float flMaxVelocity = g_cvMaxVelocity.FloatValue;
    
    for (int i = 0; i < 3; i++) {
        // Use FloatAbs for more precise comparison
        if (FloatAbs(g_vVelocity[client][i]) > flMaxVelocity) {
            g_vVelocity[client][i] = (g_vVelocity[client][i] > 0) ? flMaxVelocity : -flMaxVelocity;
        }
    }
}

bool IsPlayerOnSurfRamp(int client, float surfaceNormal[3])
{
    float startPos[3], endPos[3], mins[3], maxs[3];
    GetClientAbsOrigin(client, startPos);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);

    // Define the directions to trace: down, forward, backward, left, right
    float directions[5][3] = {
        {0.0, 0.0, -1.0}, // Down
        {1.0, 0.0, 0.0},  // Forward
        {-1.0, 0.0, 0.0}, // Backward
        {0.0, 1.0, 0.0},  // Left
        {0.0, -1.0, 0.0}  // Right
    };

    // Get player's eye angles for more accurate forward/backward traces
    float eyeAngles[3], fw[3];
    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, fw, NULL_VECTOR, NULL_VECTOR);

    // Iterate over each direction to perform the trace
    for (int i = 0; i < sizeof(directions); i++)
    {
        // Compute the end position for the trace based on the current direction
        if (i == 1) // Forward
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] + fw[j] * TRACE_DISTANCE;
            }
        }
        else if (i == 2) // Backward
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] - fw[j] * TRACE_DISTANCE;
            }
        }
        else
        {
            for (int j = 0; j < 3; j++)
            {
                endPos[j] = startPos[j] + directions[i][j] * TRACE_DISTANCE;
            }
        }

        // Perform the trace
        Handle trace = TR_TraceHullFilterEx(startPos, endPos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_World, client);

        // Check if the trace hit a surface
        if (TR_DidHit(trace))
        {
            // Retrieve the normal vector of the surface hit by the trace
            TR_GetPlaneNormal(trace, surfaceNormal);

            // Check if the surface normal is within the surfable range
            if (surfaceNormal[2] < MAX_SURFACE_NORMAL_Z && surfaceNormal[2] > MIN_SURFACE_NORMAL_Z)
            {
                delete trace;
                return true; // The player is on a surf ramp
            }
        }

        delete trace;
    }

    // If no surf ramp was found, return false
    return false;
}

public bool TraceFilter_World(int entity, int contentsMask, any data)
{
    return entity == 0 || (entity > MaxClients);
}

void AnalyzeBoard(int client, const float surfaceNormal[3]) {
    float currentVelocity[3], currentOrigin[3], eyeAngles[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", currentVelocity);
    GetClientAbsOrigin(client, currentOrigin);
    GetClientEyeAngles(client, eyeAngles);

    // Store pre-board state
    float preBoardVelocity[3], preBoardOrigin[3];
    CopyVector(g_vPreBoardVelocity[client], preBoardVelocity);
    CopyVector(g_vOrigin[client], preBoardOrigin);

    // Simulate physics for one tick to get the "ideal" post-board state
    float simulatedVelocity[3], simulatedOrigin[3];
    CopyVector(preBoardVelocity, simulatedVelocity);
    CopyVector(preBoardOrigin, simulatedOrigin);
    
    PhysicsSimulate(client, simulatedVelocity, simulatedOrigin);

    // Calculate speeds
    float preBoardSpeed = GetVectorLength(preBoardVelocity);
    float postBoardSpeed = GetVectorLength(currentVelocity);
    float simulatedSpeed = GetVectorLength(simulatedVelocity);

    // Calculate expected speed loss due to gravity
    float gravityLoss = CalculateGravitySpeedLoss(surfaceNormal, g_flTickInterval);

    // Calculate speed differences considering gravity
    float actualSpeedDiff = postBoardSpeed - (preBoardSpeed - gravityLoss);
    float idealSpeedDiff = simulatedSpeed - (preBoardSpeed - gravityLoss);
    
    // Calculate speed efficiency (uncapped)
    float speedEfficiency;
    if (idealSpeedDiff >= 0) {
        speedEfficiency = (actualSpeedDiff / idealSpeedDiff) * 100.0;
    } else {
        // If we're expected to lose speed, calculate how well we minimized the loss
        speedEfficiency = ((preBoardSpeed - postBoardSpeed) / (preBoardSpeed - simulatedSpeed)) * 100.0;
        speedEfficiency = 100.0 - speedEfficiency; // Invert so that 100% means minimal speed loss
    }

    // Calculate alignment using eye angles
    float eyeDirection[3];
    GetAngleVectors(eyeAngles, eyeDirection, NULL_VECTOR, NULL_VECTOR);
    
    float actualAngle = RadToDeg(ArcCosine(GetVectorDotProduct(eyeDirection, surfaceNormal)));
    float idealAngle = RadToDeg(ArcCosine(GetVectorDotProduct(simulatedVelocity, surfaceNormal) / simulatedSpeed));
    float alignmentError = FloatAbs(actualAngle - idealAngle);

    // Calculate strafing efficiency
    float strafingEfficiency = CalculateStrafingEfficiency(client, currentVelocity, simulatedVelocity);

    // Determine board quality
    bool perfectSpeed = (speedEfficiency >= 100.0 - g_flPerfectBoardThreshold);
    bool perfectAlignment = (alignmentError <= g_flPerfectBoardThreshold);
    bool perfectStrafing = (strafingEfficiency >= 95.0); // Assuming 95% or higher is considered perfect

    // Prepare feedback messages
    char speedFeedback[128], alignmentFeedback[128], strafingFeedback[128], overallFeedback[256];

    // Speed feedback
    if (perfectSpeed) {
        Format(speedFeedback, sizeof(speedFeedback), "Perfect speed! Efficiency: %.2f%%", speedEfficiency);
    } else if (speedEfficiency > 0) {
        Format(speedFeedback, sizeof(speedFeedback), "Speed gained, but not optimal. Efficiency: %.2f%%", speedEfficiency);
    } else {
        Format(speedFeedback, sizeof(speedFeedback), "Speed lost. Efficiency: %.2f%%", speedEfficiency);
    }

    // Alignment feedback
    if (perfectAlignment) {
        Format(alignmentFeedback, sizeof(alignmentFeedback), "Perfect alignment! Error: %.2f°", alignmentError);
    } else {
        char directionHint[32];
        if (actualAngle > idealAngle) {
            strcopy(directionHint, sizeof(directionHint), "Look more towards the ramp");
        } else {
            strcopy(directionHint, sizeof(directionHint), "Look more away from the ramp");
        }
        Format(alignmentFeedback, sizeof(alignmentFeedback), "Alignment off by %.2f°. %s", alignmentError, directionHint);
    }

    // Strafing feedback
    if (perfectStrafing) {
        Format(strafingFeedback, sizeof(strafingFeedback), "Excellent strafing! Efficiency: %.2f%%", strafingEfficiency);
    } else {
        Format(strafingFeedback, sizeof(strafingFeedback), "Improve strafing. Efficiency: %.2f%%", strafingEfficiency);
    }

    // Overall feedback
    if (perfectSpeed && perfectAlignment && perfectStrafing) {
        strcopy(overallFeedback, sizeof(overallFeedback), "Perfect board! Keep it up!");
    } else {
        char improvements[256] = "";
        if (!perfectSpeed) StrCat(improvements, sizeof(improvements), "speed, ");
        if (!perfectAlignment) StrCat(improvements, sizeof(improvements), "alignment, ");
        if (!perfectStrafing) StrCat(improvements, sizeof(improvements), "strafing, ");
        improvements[strlen(improvements) - 2] = '\0'; // Remove last comma and space
        Format(overallFeedback, sizeof(overallFeedback), "Good attempt! Focus on improving: %s", improvements);
    }

    // Display feedback on HUD
    DisplayBoardAnalysisHUD(client, speedFeedback, alignmentFeedback, strafingFeedback, overallFeedback, speedEfficiency);

    // Store the efficiency for statistics
    StoreEfficiency(client, speedEfficiency);

    if (g_bDebugMode) {
        PrintToConsole(client, "Pre-board velocity: %.2f %.2f %.2f | Speed: %.2f", 
            preBoardVelocity[0], preBoardVelocity[1], preBoardVelocity[2], preBoardSpeed);
        PrintToConsole(client, "Post-board velocity: %.2f %.2f %.2f | Speed: %.2f", 
            currentVelocity[0], currentVelocity[1], currentVelocity[2], postBoardSpeed);
        PrintToConsole(client, "Simulated velocity: %.2f %.2f %.2f | Speed: %.2f", 
            simulatedVelocity[0], simulatedVelocity[1], simulatedVelocity[2], simulatedSpeed);
        PrintToConsole(client, "Surface normal: %.2f %.2f %.2f", surfaceNormal[0], surfaceNormal[1], surfaceNormal[2]);
        PrintToConsole(client, "Actual speed difference: %.2f | Ideal speed difference: %.2f", actualSpeedDiff, idealSpeedDiff);
        PrintToConsole(client, "Speed efficiency: %.2f%%", speedEfficiency);
        PrintToConsole(client, "Actual angle: %.2f° | Ideal angle: %.2f°", actualAngle, idealAngle);
        PrintToConsole(client, "Alignment error: %.2f°", alignmentError);
        PrintToConsole(client, "Strafing efficiency: %.2f%%", strafingEfficiency);
    }
}

float CalculateGravitySpeedLoss(const float surfaceNormal[3], float time) {
    float gravity = g_cvGravity.FloatValue;
    float gravityVector[3];
    gravityVector[0] = 0.0;
    gravityVector[1] = 0.0;
    gravityVector[2] = -gravity;
    
    // Project gravity onto the surface plane
    float projectedGravity[3];
    float dot = GetVectorDotProduct(gravityVector, surfaceNormal);
    for (int i = 0; i < 3; i++) {
        projectedGravity[i] = gravityVector[i] - (surfaceNormal[i] * dot);
    }
    
    // Calculate the magnitude of the projected gravity
    float projectedGravityMagnitude = GetVectorLength(projectedGravity);
    
    // Calculate speed loss due to gravity over the given time
    return projectedGravityMagnitude * time;
}

float ClampFloat(float value, float min, float max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

float CalculateStrafingEfficiency(int client, const float currentVelocity[3], const float idealVelocity[3]) {
    float clientEyeAngles[3];
    GetClientEyeAngles(client, clientEyeAngles);
    
    float forwardMove = GetEntPropFloat(client, Prop_Data, "m_flForwardMove");
    float sideMove = GetEntPropFloat(client, Prop_Data, "m_flSideMove");
    
    float wishDir[3];
    GetWishDir(clientEyeAngles, forwardMove, sideMove, wishDir);
    
    float currentSpeed = GetVectorLength(currentVelocity);
    float idealSpeed = GetVectorLength(idealVelocity);
    
    float dotProduct = GetVectorDotProduct(currentVelocity, wishDir);
    float currentEfficiency = (dotProduct / currentSpeed) * 100.0;
    
    float idealDotProduct = GetVectorDotProduct(idealVelocity, wishDir);
    float idealEfficiency = (idealDotProduct / idealSpeed) * 100.0;
    
    return (currentEfficiency / idealEfficiency) * 100.0;
}

void GetWishDir(const float angles[3], float forwardMove, float sideMove, float wishDir[3]) {
    float fw[3], right[3];
    GetAngleVectors(angles, fw, right, NULL_VECTOR);
    
    for (int i = 0; i < 3; i++) {
        wishDir[i] = fw[i] * forwardMove + right[i] * sideMove;
    }
    
    NormalizeVector(wishDir, wishDir);
}

void StoreEfficiency(int client, float efficiency) {
    g_flBoardEfficiencies[client][g_iBoardEfficiencyIndex[client]] = efficiency;
    g_iBoardEfficiencyIndex[client] = (g_iBoardEfficiencyIndex[client] + 1) % MAX_STATS_ENTRIES;
}

/*void SimulatePoint(int client, float position[3], float velocity[3], float time)
{
    int steps = RoundToFloor(time / g_flTickInterval);
    
    for (int i = 0; i < steps; i++)
    {
        float simulatedVelocity[3], simulatedPosition[3];
        CopyVector(velocity, simulatedVelocity);
        CopyVector(position, simulatedPosition);
        
        PhysicsSimulate(client, simulatedVelocity, simulatedPosition);
        
        CopyVector(simulatedVelocity, velocity);
        CopyVector(simulatedPosition, position);
        
        // Check for collision
        TR_TraceRayFilter(position, simulatedPosition, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_World, client);
        
        if (TR_DidHit())
        {
            float normal[3];
            TR_GetPlaneNormal(null, normal);
            
            float newVelocity[3];
            ClipVelocity(velocity, normal, newVelocity, 1.0);
            CopyVector(newVelocity, velocity);
            
            TR_GetEndPosition(position);
        }
    }
}
*/


void SimulatePoint(int client, float position[3], float velocity[3], float time)
{
    int steps = RoundToFloor(time / g_flTickInterval);
    
    for (int i = 0; i < steps; i++)
    {
        float simulatedVelocity[3], simulatedPosition[3];
        CopyVector(velocity, simulatedVelocity);
        CopyVector(position, simulatedPosition);
        
        PhysicsSimulate(client, simulatedVelocity, simulatedPosition);
        
        CopyVector(simulatedVelocity, velocity);
        CopyVector(simulatedPosition, position);
        
        // Check for collision
        TR_TraceRayFilter(position, simulatedPosition, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_World, client);
        
        if (TR_DidHit())
        {
            float normal[3];
            TR_GetPlaneNormal(null, normal);
            
            float newVelocity[3];
            ClipVelocity(velocity, normal, newVelocity, 1.0);
            CopyVector(newVelocity, velocity);
            
            TR_GetEndPosition(position);
        }
    }
}

void VisualizePredictedTrajectory(int client, const float initialVelocity[3])
{
    float clientPos[3];
    GetClientAbsOrigin(client, clientPos);
    
    int color[4] = {0, 255, 0, 255}; // Green color
    float beamWidth = 1.0; // Reduced beam width for less visual clutter
    float beamLife = 0.1; // Short life for quick updates
    
    // Precache and prepare beam sprite
    int beamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
    
    float simulatedVelocity[3], simulatedPosition[3], prevPosition[3];
    CopyVector(initialVelocity, simulatedVelocity);
    CopyVector(clientPos, simulatedPosition);
    CopyVector(clientPos, prevPosition);
    
    for (int i = 1; i <= MAX_PREDICTION_POINTS; i++)
    {
        float nextSimulatedVelocity[3], nextSimulatedPosition[3];
        CopyVector(simulatedVelocity, nextSimulatedVelocity);
        CopyVector(simulatedPosition, nextSimulatedPosition);
        
        // Simulate movement for this point
        SimulatePoint(client, nextSimulatedPosition, nextSimulatedVelocity, g_flTickInterval);
        
        // Draw beam
        TE_SetupBeamPoints(
            prevPosition, 
            nextSimulatedPosition, 
            beamSprite, 
            0, // haloindex
            0, // startframe
            60, // framerate (increased for smoother animation)
            beamLife, 
            beamWidth, 
            beamWidth, // endwidth (constant width for simplicity)
            1, // fadeLength
            0.0, // amplitude
            color, 
            0 // speed
        );
        TE_SendToClient(client);
        
        CopyVector(nextSimulatedVelocity, simulatedVelocity);
        CopyVector(nextSimulatedPosition, prevPosition);
        CopyVector(nextSimulatedPosition, simulatedPosition);
    }

    char velocityText[128];
    float speed = GetVectorLength(simulatedVelocity);
    Format(velocityText, sizeof(velocityText), "Predicted Speed: %.2f u/s", speed);
    PrintHintText(client, velocityText);
}

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client));
}


void AngleVectors(const float angles[3], float fw[3], float right[3], float up[3])
{
    float sr, sp, sy, cr, cp, cy;
    
    float radx = DegToRad(angles[0]);
    float rady = DegToRad(angles[1]);
    float radz = DegToRad(angles[2]);
    
    sp = Sine(radx);
    cp = Cosine(radx);
    sy = Sine(rady);
    cy = Cosine(rady);
    sr = Sine(radz);
    cr = Cosine(radz);
    
    if (fw[0] != 0.0)
    {
        fw[0] = cp * cy;
        fw[1] = cp * sy;
        fw[2] = -sp;
    }
    
    if (right[0] != 0.0)
    {
        right[0] = (-1 * sr * sp * cy + -1 * cr * -sy);
        right[1] = (-1 * sr * sp * sy + -1 * cr * cy);
        right[2] = -1 * sr * cp;
    }
    
    if (up[0] != 0.0)
    {
        up[0] = (cr * sp * cy + -sr * -sy);
        up[1] = (cr * sp * sy + -sr * cy);
        up[2] = cr * cp;
    }
}

void ZeroVector(float vec[3]) {
    vec[0] = vec[1] = vec[2] = 0.0;
}

/*
void ClampVelocity(float velocity[3], float maxVelocity)
{
    for (int i = 0; i < 3; i++)
    {
        if (velocity[i] > maxVelocity)
            velocity[i] = maxVelocity;
        else if (velocity[i] < -maxVelocity)
            velocity[i] = -maxVelocity;
    }
}
*/

void CopyVector(const float src[3], float dest[3])
{
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

public void OnPluginEnd() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            SDKUnhook(i, SDKHook_PostThinkPost, OnPostThinkPost);
        }
    }
    
    if (g_hHudSync != null) {
        CloseHandle(g_hHudSync);
        g_hHudSync = null;
    }
}

public void OnMapStart()
{
    PrecacheModel("materials/sprites/laserbeam.vmt", true);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            ResetClientState(i);
        }
    }
    
    g_hCheckClientsTimer = CreateTimer(1.0, Timer_CheckClientsOnRamp, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    
    g_bDebugMode = g_cvDebugMode.BoolValue;
    g_flTickInterval = GetTickInterval();
    g_flPerfectBoardThreshold = g_cvPerfectBoardThreshold.FloatValue;
}

public void OnMapEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKUnhook(i, SDKHook_PostThinkPost, OnPostThinkPost);
        }
    }
    
    // Kill any timers or hooks that were created
    if (g_hCheckClientsTimer != INVALID_HANDLE)
    {
        KillTimer(g_hCheckClientsTimer);
        g_hCheckClientsTimer = INVALID_HANDLE;
    }
    
    // Reset any global variables
    g_bDebugMode = false;
    g_flTickInterval = 0.0;
    g_flPerfectBoardThreshold = 0.0;
}

public Action Timer_CheckClientsOnRamp(Handle timer) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsPlayerAlive(i)) {
            float surfaceNormal[3];
            if (IsPlayerOnSurfRamp(i, surfaceNormal)) {               
                if (g_bDebugMode) {
                    PrintToConsole(i, "You are on a surf ramp!");
                }
            }
        }
    }
    return Plugin_Continue;
}

float CalculateAverageEfficiency(int client) {
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        if (g_flBoardEfficiencies[client][i] != 0.0) {
            total += g_flBoardEfficiencies[client][i];
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

public Action Command_SurfStats(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    float avgEfficiency = CalculateAverageEfficiency(client);
    int totalBoards = GetTotalBoards(client);
    float bestEfficiency = GetBestEfficiency(client);
    float recentAvgEfficiency = CalculateRecentAverageEfficiency(client, 10); // Last 10 boards

    DisplaySurfStatsHUD(client, avgEfficiency, totalBoards, bestEfficiency, recentAvgEfficiency);

    return Plugin_Handled;
}

int GetTotalBoards(int client) {
    int count = 0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        if (g_flBoardEfficiencies[client][i] != 0.0) {
            count++;
        }
    }
    return count;
}

float GetBestEfficiency(int client) {
    float best = 0.0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        if (g_flBoardEfficiencies[client][i] > best) {
            best = g_flBoardEfficiencies[client][i];
        }
    }
    return best;
}

float CalculateRecentAverageEfficiency(int client, int recentCount) {
    float total = 0.0;
    int count = 0;
    int startIndex = (g_iBoardEfficiencyIndex[client] - 1 + MAX_STATS_ENTRIES) % MAX_STATS_ENTRIES;
    
    for (int i = 0; i < recentCount && i < MAX_STATS_ENTRIES; i++) {
        int index = (startIndex - i + MAX_STATS_ENTRIES) % MAX_STATS_ENTRIES;
        if (g_flBoardEfficiencies[client][index] != 0.0) {
            total += g_flBoardEfficiencies[client][index];
            count++;
        } else {
            break; // No more recent entries
        }
    }
    
    return (count > 0) ? (total / float(count)) : 0.0;
}

void DisplayBoardAnalysisHUD(int client, const char[] speedFeedback, const char[] alignmentFeedback, const char[] strafingFeedback, const char[] overallFeedback, float speedEfficiency) {
    if (g_hHudSync == null) return;

    // Determine color based on speed efficiency
    int color1[4], color2[4] = {0, 0, 0, 0}; // color2 is set to black (no secondary color effect)
    if (speedEfficiency >= 90.0) {
        color1 = {0, 255, 0, 255}; // Green for excellent performance
    } else if (speedEfficiency >= 70.0) {
        color1 = {255, 255, 0, 255}; // Yellow for good performance
    } else {
        color1 = {255, 0, 0, 255}; // Red for poor performance
    }

    SetHudTextParamsEx(-1.0, 0.25, 5.0, color1, color2, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_hHudSync, "Board Analysis:\n%s\n%s\n%s\n%s", 
        speedFeedback, alignmentFeedback, strafingFeedback, overallFeedback);
}

void DisplaySurfStatsHUD(int client, float avgEfficiency, int totalBoards, float bestEfficiency, float recentAvgEfficiency) {
    if (g_hHudSync == null) return;

    char formattedAvgEfficiency[32], formattedBestEfficiency[32], formattedRecentAvgEfficiency[32];
    
    FormatEfficiencyWithColor(avgEfficiency, formattedAvgEfficiency, sizeof(formattedAvgEfficiency));
    FormatEfficiencyWithColor(bestEfficiency, formattedBestEfficiency, sizeof(formattedBestEfficiency));
    FormatEfficiencyWithColor(recentAvgEfficiency, formattedRecentAvgEfficiency, sizeof(formattedRecentAvgEfficiency));

    int color1[4] = {255, 255, 255, 255}; // White color for stats
    int color2[4] = {0, 0, 0, 0}; // No secondary color effect

    SetHudTextParamsEx(-1.0, 0.1, 10.0, color1, color2, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_hHudSync, "Surf Statistics:\nAverage Efficiency: %s\nTotal Boards: %d\nBest Efficiency: %s\nRecent Avg (Last 10): %s", 
        formattedAvgEfficiency, totalBoards, formattedBestEfficiency, formattedRecentAvgEfficiency);
}

void FormatEfficiencyWithColor(float efficiency, char[] buffer, int bufferSize) {
    char colorCode[16];
    if (efficiency >= 90.0) {
        strcopy(colorCode, sizeof(colorCode), "\x04"); // Green
    } else if (efficiency >= 70.0) {
        strcopy(colorCode, sizeof(colorCode), "\x09"); // Yellow
    } else {
        strcopy(colorCode, sizeof(colorCode), "\x02"); // Red
    }
    
    Format(buffer, bufferSize, "%s%.2f%%\x01", colorCode, efficiency);
}
