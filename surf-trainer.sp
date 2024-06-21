#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.2"
#define EPSILON 0.00001
#define TRACE_DISTANCE 64.0
#define MAX_SURFACE_NORMAL_Z 0.7
#define MIN_SURFACE_NORMAL_Z 0.1
#define MAX_PREDICTION_POINTS 10
#define PROCESS_INTERVAL 0.1 
#define MAX_WISH_SPEED 30.0

ConVar g_cvAirAccelerate;
ConVar g_cvMaxVelocity;
ConVar g_cvGravity;
ConVar g_cvDebugMode;
ConVar g_cvPerfectBoardThreshold;

bool g_bDebugMode;
float g_flTickInterval;
float g_flPerfectBoardThreshold;
Handle g_hCheckClientsTimer = INVALID_HANDLE;

// Player-specific variables
float g_vVelocity[MAXPLAYERS + 1][3];
float g_vOrigin[MAXPLAYERS + 1][3];
bool g_bTouchingRamp[MAXPLAYERS + 1];
bool g_bJustStartedTouchingRamp[MAXPLAYERS + 1];
float g_vPreBoardVelocity[MAXPLAYERS + 1][3];
float g_flLastProcessTime[MAXPLAYERS + 1];


public void OnPluginStart() {
    CreateConVar("sm_surftrainer_version", PLUGIN_VERSION, "Surf trainer version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
    g_cvAirAccelerate = FindConVar("sv_airaccelerate");
    g_cvMaxVelocity = FindConVar("sv_maxvelocity");
    g_cvGravity = FindConVar("sv_gravity");
    g_cvDebugMode = CreateConVar("sm_surftrainer_debug", "0", "Enable debug mode", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPerfectBoardThreshold = CreateConVar("sm_surftrainer_threshold", "2.0", "Threshold for perfect board detection (in units)", FCVAR_NOTIFY, true, 0.0);

    g_bDebugMode = g_cvDebugMode.BoolValue;
    g_flTickInterval = GetTickInterval();
    g_flPerfectBoardThreshold = g_cvPerfectBoardThreshold.FloatValue;

    HookEvent("player_spawn", Event_PlayerSpawn);
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }

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
    if (currentTime - g_flLastProcessTime[client] < PROCESS_INTERVAL)
    {
        return;
    }

    g_flLastProcessTime[client] = currentTime;

    SimulatePlayerMovement(client);
}

void PhysicsSimulate(int client, float vOutVelocity[3], float vOutOrigin[3]) {
    float vWishDir[3], vWishVel[3];
    float flWishSpeed;
    
    StartGravity(client);
    AirMove(client, vWishDir, vWishVel, flWishSpeed);
    FinishGravity(client);
    
    TryPlayerMove(client, vOutOrigin);
    
    // Final velocity check
    CheckVelocity(client, vOutVelocity);
    
    vOutVelocity[2] = 0.0; // Zero out Z component
}

void SimulatePlayerMovement(int client) {
    float vNewVelocity[3], vNewOrigin[3];
    
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

    // Simulate physics
    PhysicsSimulate(client, vNewVelocity, vNewOrigin);

    // Visualize predicted trajectory
    VisualizePredictedTrajectory(client, vNewVelocity);

    if (g_bDebugMode) {
        float xyVelocity[3];
        xyVelocity[0] = vNewVelocity[0];
        xyVelocity[1] = vNewVelocity[1];
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
    float vVelocity[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVelocity);

    float flCurrentSpeed = GetVectorDotProduct(vVelocity, vWishDir);
    float flAddSpeed = flWishSpeed - flCurrentSpeed;

    if (flAddSpeed <= 0)
    {
        return;
    }

    float flAccelSpeed = flAirAccelerate * flWishSpeed * GetTickInterval();

    if (flAccelSpeed > flAddSpeed)
    {
        flAccelSpeed = flAddSpeed;
    }

    for (int i = 0; i < 3; i++)
    {
        vVelocity[i] += flAccelSpeed * vWishDir[i];
    }

    SetEntPropVector(client, Prop_Data, "m_vecVelocity", vVelocity);
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
            vEnd[i] = g_vOrigin[client][i] + vTotalLeftToMove[i] * flTimeLeft;
        }
        
        TR_TraceHullFilter(g_vOrigin[client], vEnd, 
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
            CopyVector(g_vOrigin[client], vOutOrigin);
            CopyVector(vOriginalVelocity, g_vVelocity[client]);
            return;
        }
    }
    
    CopyVector(g_vOrigin[client], vOutOrigin);
    CopyVector(vClippedVelocity, g_vVelocity[client]);
}

void ClipVelocity(const float vIn[3], const float vNormal[3], float vOut[3], float flOverbounce) {
    float flBackoff = GetVectorDotProduct(vIn, vNormal) * flOverbounce;
    
    for (int i = 0; i < 3; i++) {
        float flChange = vNormal[i] * flBackoff;
        vOut[i] = vIn[i] - flChange;
        
        if (vOut[i] > -EPSILON && vOut[i] < EPSILON) {
            vOut[i] = 0.0;
        }
    }
    
    float flAdjust = GetVectorDotProduct(vOut, vNormal);
    if (flAdjust < 0.0) {
        for (int i = 0; i < 3; i++) {
            vOut[i] -= vNormal[i] * flAdjust;
        }
    }
}

void CheckVelocity(int client, float vOutVelocity[3]) {
    float flMaxVelocity = g_cvMaxVelocity.FloatValue;
    
    for (int i = 0; i < 3; i++) {
        // Use FloatAbs for more precise comparison
        if (FloatAbs(g_vVelocity[client][i]) > flMaxVelocity) {
            g_vVelocity[client][i] = (g_vVelocity[client][i] > 0) ? flMaxVelocity : -flMaxVelocity;
        }
    }
    
    CopyVector(g_vVelocity[client], vOutVelocity);
}

bool IsPlayerOnSurfRamp(int client, float surfaceNormal[3]) {
    float startPos[3], endPos[3];
    GetClientAbsOrigin(client, startPos);
    endPos[0] = startPos[0];
    endPos[1] = startPos[1];
    endPos[2] = startPos[2] - TRACE_DISTANCE;

    TR_TraceRayFilter(startPos, endPos, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_World, client);

    if (TR_DidHit()) {
        TR_GetPlaneNormal(null, surfaceNormal);
        return (surfaceNormal[2] < MAX_SURFACE_NORMAL_Z && surfaceNormal[2] > MIN_SURFACE_NORMAL_Z);
    }

    return false;
}

public bool TraceFilter_World(int entity, int contentsMask) {
    return entity == 0;
}

void AnalyzeBoard(int client, const float surfaceNormal[3]) {
    float currentVelocity[3], currentOrigin[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", currentVelocity);
    GetClientAbsOrigin(client, currentOrigin);

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

    // Calculate speed differences
    float actualSpeedDiff = postBoardSpeed - preBoardSpeed;
    float idealSpeedDiff = simulatedSpeed - preBoardSpeed;
    
    // Calculate speed efficiency
    float speedEfficiency;
    if (idealSpeedDiff != 0.0) {
        speedEfficiency = (actualSpeedDiff / idealSpeedDiff) * 100.0;
    } else {
        speedEfficiency = (actualSpeedDiff >= 0.0) ? 100.0 : -100.0;
    }

    // Calculate alignment
    float actualAngle = RadToDeg(ArcCosine(GetVectorDotProduct(currentVelocity, surfaceNormal) / postBoardSpeed));
    float idealAngle = RadToDeg(ArcCosine(GetVectorDotProduct(simulatedVelocity, surfaceNormal) / simulatedSpeed));
    float alignmentError = FloatAbs(actualAngle - idealAngle);

    // Determine board quality
    bool perfectSpeed = (speedEfficiency >= 100.0 - g_flPerfectBoardThreshold);
    bool perfectAlignment = (alignmentError <= g_flPerfectBoardThreshold);

    char speedFeedback[128], alignmentFeedback[128];

    // Speed feedback
    if (perfectSpeed) {
        Format(speedFeedback, sizeof(speedFeedback), "Perfect speed! Efficiency: %.2f%%", speedEfficiency);
    } else if (speedEfficiency > 0) {
        Format(speedFeedback, sizeof(speedFeedback), "Speed gained. Efficiency: %.2f%%", speedEfficiency);
    } else {
        Format(speedFeedback, sizeof(speedFeedback), "Speed lost. Efficiency: %.2f%%", speedEfficiency);
    }

    // Alignment feedback
    if (perfectAlignment) {
        Format(alignmentFeedback, sizeof(alignmentFeedback), "Perfect alignment! Error: %.2f°", alignmentError);
    } else {
        Format(alignmentFeedback, sizeof(alignmentFeedback), "Alignment off by %.2f°", alignmentError);
    }

    // Provide feedback to the player
    PrintToChat(client, "\x04[Surf Trainer] Board Analysis:");
    PrintToChat(client, "\x05%s", speedFeedback);
    PrintToChat(client, "\x05%s", alignmentFeedback);

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
        PrintToConsole(client, "Perfect board threshold: %.4f", g_flPerfectBoardThreshold);
    }
}

/*
void CalculateParallelVelocity(const float velocity[3], const float normal[3], float parallelVelocity[3]) {
    float dot = GetVectorDotProduct(velocity, normal);
    
    for (int i = 0; i < 3; i++) {
        parallelVelocity[i] = velocity[i] - (normal[i] * dot);
    }
}
*/

void VisualizePredictedTrajectory(int client, const float predictedVelocity[3]) {
    float clientPos[3], endPos[3];
    GetClientAbsOrigin(client, clientPos);
    
    int color[4] = {0, 255, 0, 255}; // Green color
    float beamWidth = 1.0; // Reduced beam width for less visual clutter
    float beamLife = 0.1; // Short life for quick updates
    
    // Precache and prepare beam sprite
    int beamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
    
    for (int i = 1; i <= MAX_PREDICTION_POINTS; i++) {
        float simulatedVelocity[3], simulatedPosition[3];
        CopyVector(predictedVelocity, simulatedVelocity);
        CopyVector(clientPos, simulatedPosition);
        
        // Simulate movement for this point (including Z for accuracy)
        SimulatePoint(simulatedPosition, simulatedVelocity, i * g_flTickInterval);
        
        // Draw beam... This does need improvement
        TE_SetupBeamPoints(
            (i == 1) ? clientPos : endPos, 
            simulatedPosition, 
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
        
        CopyVector(simulatedPosition, endPos);
    }

    char velocityText[128];
    float speed = GetVectorLength(predictedVelocity);
    Format(velocityText, sizeof(velocityText), "Predicted Speed: %.2f u/s", speed);
    PrintHintText(client, velocityText);
}

void SimulatePoint(float position[3], float velocity[3], float time) {
    float gravity = g_cvGravity.FloatValue;
    
    for (int i = 0; i < 3; i++) {
        position[i] += velocity[i] * time;
        if (i == 2) { // Apply gravity only to Z-axis
            position[i] -= 0.5 * gravity * time * time;
            velocity[i] -= gravity * time;
        }
    }
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

void CopyVector(const float from[3], float to[3]) {
    to[0] = from[0];
    to[1] = from[1];
    to[2] = from[2];
}

public void OnPluginEnd() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            SDKUnhook(i, SDKHook_PostThinkPost, OnPostThinkPost);
        }
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
                    PrintToChat(i, "You are on a surf ramp!");
                }
            }
        }
    }
    return Plugin_Continue;
}
