unit g_triggers;

interface

uses
  MAPSTRUCT, e_graphics, Windows, MAPDEF, g_basic, g_sound,
  BinEditor;

type
  TActivator = record
    UID:     Word;
    TimeOut: Word;
  end;
  TTrigger = record
    ID:               DWORD;
    ClientID:         DWORD;
    TriggerType:      Byte;
    X, Y:             Integer;
    Width, Height:    Word;
    Enabled:          Boolean;
    ActivateType:     Byte;
    Keys:             Byte;
    TexturePanel:     Integer;
    TexturePanelType: Word;

    TimeOut:          Word;
    ActivateUID:      Word;
    Activators:       array of TActivator;
    PlayerCollide:    Boolean;
    DoorTime:         Integer;
    PressTime:        Integer;
    PressCount:       Integer;
    SoundPlayCount:   Integer;
    Sound:            TPlayableSound;
    AutoSpawn:        Boolean;
    SpawnCooldown:    Integer;
    SpawnedCount:     Integer;
    ShotPanelType:    Word;
    ShotPanelTime:    Integer;
    ShotSightTime:    Integer;
    ShotSightTimeout: Integer;
    ShotSightTarget:  Word;
    ShotSightTargetN: Word;
    ShotAmmoCount:    Word;
    ShotReloadTime:   Integer;

    Data:             TTriggerData;
  end;

function g_Triggers_Create(Trigger: TTrigger): DWORD;
procedure g_Triggers_Update();
procedure g_Triggers_Press(ID: DWORD; ActivateType: Byte);
function g_Triggers_PressR(X, Y: Integer; Width, Height: Word; UID: Word;
                           ActivateType: Byte; IgnoreList: DWArray = nil): DWArray;
procedure g_Triggers_PressL(X1, Y1, X2, Y2: Integer; UID: DWORD; ActivateType: Byte);
procedure g_Triggers_PressC(CX, CY: Integer; Radius: Word; UID: Word; ActivateType: Byte);
procedure g_Triggers_OpenAll();
procedure g_Triggers_DecreaseSpawner(ID: DWORD);
procedure g_Triggers_Free();
procedure g_Triggers_SaveState(var Mem: TBinMemoryWriter);
procedure g_Triggers_LoadState(var Mem: TBinMemoryReader);

var
  gTriggerClientID: Integer = 0;
  gTriggers: array of TTrigger;
  gSecretsCount: Integer = 0;
  gMonstersSpawned: array of LongInt = nil;

implementation

uses
  g_player, g_map, Math, g_gfx, g_game, g_textures,
  g_console, g_monsters, g_items, g_phys, g_weapons,
  WADEDITOR, g_main, SysUtils, e_log, g_language,
  g_options, g_net, g_netmsg;

const
  TRIGGER_SIGNATURE = $52475254; // 'TRGR'
  TRAP_DAMAGE = 1000;

function FindTrigger(): DWORD;
var
  i: Integer;
begin
  if gTriggers <> nil then
    for i := 0 to High(gTriggers) do
      if gTriggers[i].TriggerType = TRIGGER_NONE then
      begin
        Result := i;
        Exit;
      end;

  if gTriggers = nil then
  begin
    SetLength(gTriggers, 8);
    Result := 0;
  end
  else
  begin
    Result := High(gTriggers) + 1;
    SetLength(gTriggers, Length(gTriggers) + 8);
  end;
end;

function CloseDoor(PanelID: Integer; NoSound: Boolean; d2d: Boolean): Boolean;
var
  a, b, c: Integer;
begin
  Result := False;

  if PanelID = -1 then Exit;

  if not d2d then
  begin
    with gWalls[PanelID] do
    begin
      if g_CollidePlayer(X, Y, Width, Height) or
         g_CollideMonster(X, Y, Width, Height) then Exit;

      if not Enabled then
      begin
        if not NoSound then
        begin
          g_Sound_PlayExAt('SOUND_GAME_DOORCLOSE', X, Y);
          if g_Game_IsServer and g_Game_IsNet then
            MH_SEND_Sound(X, Y, 'SOUND_GAME_DOORCLOSE');
        end;
        g_Map_EnableWall(PanelID);
        Result := True;
      end;
    end;
  end
  else
  begin
    if gDoorMap = nil then Exit;

    c := -1;
    for a := 0 to High(gDoorMap) do
    begin
      for b := 0 to High(gDoorMap[a]) do
        if gDoorMap[a, b] = DWORD(PanelID) then
        begin
          c := a;
          Break;
        end;

      if c <> -1 then Break;
    end;
    if c = -1 then Exit;

    for b := 0 to High(gDoorMap[c]) do
      with gWalls[gDoorMap[c, b]] do
      begin
        if g_CollidePlayer(X, Y, Width, Height) or
          g_CollideMonster(X, Y, Width, Height) then Exit;
      end;

    if not NoSound then
      for b := 0 to High(gDoorMap[c]) do
        if not gWalls[gDoorMap[c, b]].Enabled then
        begin
          with gWalls[PanelID] do
          begin
            g_Sound_PlayExAt('SOUND_GAME_DOORCLOSE', X, Y);
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_Sound(X, Y, 'SOUND_GAME_DOORCLOSE');
          end;
          Break;
        end;

    for b := 0 to High(gDoorMap[c]) do
      if not gWalls[gDoorMap[c, b]].Enabled then
      begin
        g_Map_EnableWall(gDoorMap[c, b]);
        Result := True;
      end;
  end;
end;

procedure CloseTrap(PanelID: Integer; NoSound: Boolean; d2d: Boolean);
var
  a, b, c: Integer;
begin
  if PanelID = -1 then Exit;

  if not d2d then
  begin
    with gWalls[PanelID] do
      if (not NoSound) and (not Enabled) then
      begin
        g_Sound_PlayExAt('SOUND_GAME_SWITCH1', X, Y);
        if g_Game_IsServer and g_Game_IsNet then
          MH_SEND_Sound(X, Y, 'SOUND_GAME_SWITCH1');
      end;


    with gWalls[PanelID] do
    begin
      if gPlayers <> nil then
        for a := 0 to High(gPlayers) do
          if (gPlayers[a] <> nil) and gPlayers[a].Live and
              gPlayers[a].Collide(X, Y, Width, Height) then
            gPlayers[a].Damage(TRAP_DAMAGE, 0, 0, 0, HIT_TRAP);

      if gMonsters <> nil then
        for a := 0 to High(gMonsters) do
          if (gMonsters[a] <> nil) and gMonsters[a].Live and
          g_Obj_Collide(X, Y, Width, Height, @gMonsters[a].Obj) then
            gMonsters[a].Damage(TRAP_DAMAGE, 0, 0, 0, HIT_TRAP);

      if not Enabled then g_Map_EnableWall(PanelID);
    end;
  end
  else
  begin
    if gDoorMap = nil then Exit;

    c := -1;
    for a := 0 to High(gDoorMap) do
    begin
      for b := 0 to High(gDoorMap[a]) do
        if gDoorMap[a, b] = DWORD(PanelID) then
        begin
          c := a;
          Break;
        end;

      if c <> -1 then Break;
    end;
    if c = -1 then Exit;

    if not NoSound then
      for b := 0 to High(gDoorMap[c]) do
        if not gWalls[gDoorMap[c, b]].Enabled then
        begin
          with gWalls[PanelID] do
          begin
            g_Sound_PlayExAt('SOUND_GAME_SWITCH1', X, Y);
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_Sound(X, Y, 'SOUND_GAME_SWITCH1');
          end;
          Break;
        end;

    for b := 0 to High(gDoorMap[c]) do
      with gWalls[gDoorMap[c, b]] do
      begin
        if gPlayers <> nil then
          for a := 0 to High(gPlayers) do
            if (gPlayers[a] <> nil) and gPlayers[a].Live and
            gPlayers[a].Collide(X, Y, Width, Height) then
              gPlayers[a].Damage(TRAP_DAMAGE, 0, 0, 0, HIT_TRAP);

        if gMonsters <> nil then
          for a := 0 to High(gMonsters) do
            if (gMonsters[a] <> nil) and gMonsters[a].Live and
            g_Obj_Collide(X, Y, Width, Height, @gMonsters[a].Obj) then
              gMonsters[a].Damage(TRAP_DAMAGE, 0, 0, 0, HIT_TRAP);

        if not Enabled then g_Map_EnableWall(gDoorMap[c, b]);
      end;
  end;
end;

function OpenDoor(PanelID: Integer; NoSound: Boolean; d2d: Boolean): Boolean;
var
  a, b, c: Integer;
begin
  Result := False;

  if PanelID = -1 then Exit;

  if not d2d then
  begin
    with gWalls[PanelID] do
      if Enabled then
      begin
        if not NoSound then
        begin
          g_Sound_PlayExAt('SOUND_GAME_DOOROPEN', X, Y);
          if g_Game_IsServer and g_Game_IsNet then
            MH_SEND_Sound(X, Y, 'SOUND_GAME_DOOROPEN');
        end;
        g_Map_DisableWall(PanelID);
        Result := True;
      end;
  end
  else
  begin
    if gDoorMap = nil then Exit;

    c := -1;
    for a := 0 to High(gDoorMap) do
    begin
      for b := 0 to High(gDoorMap[a]) do
        if gDoorMap[a, b] = DWORD(PanelID) then
        begin
          c := a;
          Break;
        end;

      if c <> -1 then Break;
    end;
    if c = -1 then Exit;

    if not NoSound then
      for b := 0 to High(gDoorMap[c]) do
        if gWalls[gDoorMap[c, b]].Enabled then
        begin
          with gWalls[PanelID] do
          begin
            g_Sound_PlayExAt('SOUND_GAME_DOOROPEN', X, Y);
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_Sound(X, Y, 'SOUND_GAME_DOOROPEN');
          end;
          Break;
        end;

    for b := 0 to High(gDoorMap[c]) do
      if gWalls[gDoorMap[c, b]].Enabled then
      begin
        g_Map_DisableWall(gDoorMap[c, b]);
        Result := True;
      end;
  end;
end;

function SetLift(PanelID: Integer; d: Integer; NoSound: Boolean; d2d: Boolean): Boolean;
var
  a, b, c, t: Integer;
begin
  t := 0;
  Result := False;

  if PanelID = -1 then Exit;

  if (gLifts[PanelID].PanelType = PANEL_LIFTUP) or
     (gLifts[PanelID].PanelType = PANEL_LIFTDOWN) then
    case d of
      0: t := 0;
      1: t := 1;
      else t := IfThen(gLifts[PanelID].LiftType = 1, 0, 1);
    end
  else if (gLifts[PanelID].PanelType = PANEL_LIFTLEFT) or
          (gLifts[PanelID].PanelType = PANEL_LIFTRIGHT) then
    case d of
      0: t := 2;
      1: t := 3;
      else t := IfThen(gLifts[PanelID].LiftType = 2, 3, 2);
    end;

  if not d2d then
  begin
    with gLifts[PanelID] do
      if LiftType <> t then
      begin
        g_Map_SetLift(PanelID, t);

        {if not NoSound then
          g_Sound_PlayExAt('SOUND_GAME_SWITCH0', X, Y);}
        Result := True;
      end;
  end
  else // ��� � D2d
  begin
    if gLiftMap = nil then Exit;

    c := -1;
    for a := 0 to High(gLiftMap) do
    begin
      for b := 0 to High(gLiftMap[a]) do
        if gLiftMap[a, b] = DWORD(PanelID) then
        begin
          c := a;
          Break;
        end;

      if c <> -1 then Break;
    end;
    if c = -1 then Exit;

    {if not NoSound then
      for b := 0 to High(gLiftMap[c]) do
        if gLifts[gLiftMap[c, b]].LiftType <> t then
        begin
          with gLifts[PanelID] do
            g_Sound_PlayExAt('SOUND_GAME_SWITCH0', X, Y);
          Break;
        end;}

    for b := 0 to High(gLiftMap[c]) do
      with gLifts[gLiftMap[c, b]] do
        if LiftType <> t then
        begin
          g_Map_SetLift(gLiftMap[c, b], t);

          Result := True;
        end;
  end;
end;

procedure MakeShot(var Trigger: TTrigger; wx, wy, dx, dy: Integer; TargetUID: Word);
var
  Projectile: Boolean;
  snd: string;
  TextureID: DWORD;
  Anim: TAnimation;
begin
  with Trigger do
    if (Data.ShotAmmo = 0) or
       ((Data.ShotAmmo > 0) and (ShotAmmoCount > 0)) then
    begin
      if (Data.ShotPanelID <> -1) and (ShotPanelTime = 0) then
      begin
        g_Map_SwitchTexture(ShotPanelType, Data.ShotPanelID);
        ShotPanelTime := 4; // ����� �� ������� ��������
      end;

      if Data.ShotIntSight > 0 then
        ShotSightTimeout := 180; // ~= 5 ������

      if ShotAmmoCount > 0 then Dec(ShotAmmoCount);
      Projectile := True;
      snd := 'SOUND_WEAPON_FIREROCKET';

      dx := dx + Random(Data.ShotAccuracy) - Random(Data.ShotAccuracy);
      dy := dy + Random(Data.ShotAccuracy) - Random(Data.ShotAccuracy);

      case Data.ShotType of
        TRIGGER_SHOT_PISTOL:
          begin
            g_Weapon_pistol(wx, wy, dx, dy, 0, True);
            Projectile := False;
            snd := 'SOUND_WEAPON_FIREPISTOL';
            if Data.ShotSound then
            begin
              g_Player_CreateShell(wx, wy, 0, -2, SHELL_BULLET);
              if g_Game_IsNet then
                MH_SEND_Effect(wx, wy, 0, NET_GFX_SHELL1);
            end;
          end;

        TRIGGER_SHOT_BULLET:
          begin
            g_Weapon_mgun(wx, wy, dx, dy, 0, True);
            Projectile := False;
            if gSoundEffectsDF then snd := 'SOUND_WEAPON_FIRECGUN'
            else snd := 'SOUND_WEAPON_FIREPISTOL';
            if Data.ShotSound then
            begin
              g_Player_CreateShell(wx, wy, 0, -2, SHELL_BULLET);
              if g_Game_IsNet then
                MH_SEND_Effect(wx, wy, 0, NET_GFX_SHELL1);
            end;
          end;

        TRIGGER_SHOT_SHOTGUN:
          begin
            g_Weapon_Shotgun(wx, wy, dx, dy, 0, True);
            Projectile := False;
            snd := 'SOUND_WEAPON_FIRESHOTGUN';
            if Data.ShotSound then
            begin
              g_Player_CreateShell(wx, wy, 0, -2, SHELL_SHELL);
              if g_Game_IsNet then
                MH_SEND_Effect(wx, wy, 0, NET_GFX_SHELL2);
            end;
          end;

        TRIGGER_SHOT_SSG:
          begin
            g_Weapon_DShotgun(wx, wy, dx, dy, 0, True);
            Projectile := False;
            snd := 'SOUND_WEAPON_FIRESHOTGUN2';
            if Data.ShotSound then
            begin
              g_Player_CreateShell(wx, wy, 0, -2, SHELL_SHELL);
              g_Player_CreateShell(wx, wy, 0, -2, SHELL_SHELL);
              if g_Game_IsNet then
                MH_SEND_Effect(wx, wy, 0, NET_GFX_SHELL3);
            end;
          end;

        TRIGGER_SHOT_IMP:
          begin
            g_Weapon_ball1(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREBALL';
          end;

        TRIGGER_SHOT_PLASMA:
          begin
            g_Weapon_Plasma(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREPLASMA';
          end;

        TRIGGER_SHOT_SPIDER:
          begin
            g_Weapon_aplasma(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREPLASMA';
          end;

        TRIGGER_SHOT_CACO:
          begin
            g_Weapon_ball2(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREBALL';
          end;

        TRIGGER_SHOT_BARON:
          begin
            g_Weapon_ball7(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREBALL';
          end;

        TRIGGER_SHOT_MANCUB:
          begin
            g_Weapon_manfire(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREBALL';
          end;

        TRIGGER_SHOT_REV:
          begin
            g_Weapon_revf(wx, wy, dx, dy, 0, TargetUID, -1, True);
            snd := 'SOUND_WEAPON_FIREREV';
          end;

        TRIGGER_SHOT_ROCKET:
          begin
            g_Weapon_Rocket(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREROCKET';
          end;

        TRIGGER_SHOT_BFG:
          begin
            g_Weapon_BFGShot(wx, wy, dx, dy, 0, -1, True);
            snd := 'SOUND_WEAPON_FIREBFG';
          end;

        TRIGGER_SHOT_EXPL:
          begin
            if g_Frames_Get(TextureID, 'FRAMES_EXPLODE_ROCKET') then
            begin
              Anim := TAnimation.Create(TextureID, False, 6);
              Anim.Blending := False;
              g_GFX_OnceAnim(wx-64, wy-64, Anim);
              Anim.Free();
            end;
            Projectile := False;
            g_Weapon_Explode(wx, wy, 60, 0);
            snd := 'SOUND_WEAPON_EXPLODEROCKET';
          end;

        TRIGGER_SHOT_BFGEXPL:
          begin
            if g_Frames_Get(TextureID, 'FRAMES_EXPLODE_BFG') then
            begin
              Anim := TAnimation.Create(TextureID, False, 6);
              Anim.Blending := False;
              g_GFX_OnceAnim(wx-64, wy-64, Anim);
              Anim.Free();
            end;
            Projectile := False;
            g_Weapon_BFG9000(wx, wy, 0);
            snd := 'SOUND_WEAPON_EXPLODEBFG';
          end;
      end;

      if g_Game_IsNet and g_Game_IsServer then
        case Data.ShotType of
          TRIGGER_SHOT_EXPL:
            MH_SEND_Effect(wx, wy, Byte(Data.ShotSound), NET_GFX_EXPLODE);
          TRIGGER_SHOT_BFGEXPL:
            MH_SEND_Effect(wx, wy, Byte(Data.ShotSound), NET_GFX_BFGEXPL);
          else
          begin
            if Projectile then
              MH_SEND_CreateShot(LastShotID);
            if Data.ShotSound then
              MH_SEND_Sound(wx, wy, snd);
          end;
        end;

      if Data.ShotSound then
        g_Sound_PlayExAt(snd, wx, wy);
    end
    else
      if (Data.ShotIntReload > 0) and (ShotReloadTime = 0) then
        ShotReloadTime := Data.ShotIntReload; // ����� �� ����������� �����
end;

procedure MakeEffect(X, Y, VX, VY: Integer; T, ST, CR, CG, CB: Byte; Silent, Send: Boolean);
var
  FramesID: DWORD;
  Anim: TAnimation;
begin
  if T = TRIGGER_EFFECT_PARTICLE then
    case ST of
      TRIGGER_EFFECT_SLIQUID:
      begin
        if (CR = 255) and (CG = 0) and (CB = 0) then
          g_GFX_SimpleWater(X, Y, 1, VX, VY, 1, 0, 0, 0)
        else if (CR = 0) and (CG = 255) and (CB = 0) then
          g_GFX_SimpleWater(X, Y, 1, VX, VY, 2, 0, 0, 0)
        else if (CR = 0) and (CG = 0) and (CB = 255) then
          g_GFX_SimpleWater(X, Y, 1, VX, VY, 3, 0, 0, 0)
        else
          g_GFX_SimpleWater(X, Y, 1, VX, VY, 0, 0, 0, 0);
      end;
      TRIGGER_EFFECT_LLIQUID:
        g_GFX_SimpleWater(X, Y, 1, VX, VY, 4, CR, CG, CB);
      TRIGGER_EFFECT_DLIQUID:
        g_GFX_SimpleWater(X, Y, 1, VX, VY, 5, CR, CG, CB);
      TRIGGER_EFFECT_BLOOD:
        g_GFX_Blood(X, Y, 1, VX, VY, 0, 0, CR, CG, CB);
      TRIGGER_EFFECT_SPARK:
        g_GFX_Spark(X, Y, 1, GetAngle2(VX, VY), 0, 0);
      TRIGGER_EFFECT_BUBBLE:
        g_GFX_Bubbles(X, Y, 1, 0, 0);
    end;
  if T = TRIGGER_EFFECT_ANIMATION then
    case ST of
      EFFECT_TELEPORT: begin
        if g_Frames_Get(FramesID, 'FRAMES_TELEPORT') then
        begin
          Anim := TAnimation.Create(FramesID, False, 3);
          if not Silent then
            g_Sound_PlayExAt('SOUND_GAME_TELEPORT', X, Y);
          g_GFX_OnceAnim(X-32, Y-32, Anim);
          Anim.Free();
        end;
        if Send and g_Game_IsServer and g_Game_IsNet then
          MH_SEND_Effect(X, Y, Byte(not Silent), NET_GFX_TELE);
      end;
      EFFECT_RESPAWN: begin
        if g_Frames_Get(FramesID, 'FRAMES_ITEM_RESPAWN') then
        begin
          Anim := TAnimation.Create(FramesID, False, 4);
          if not Silent then
            g_Sound_PlayExAt('SOUND_ITEM_RESPAWNITEM', X, Y);
          g_GFX_OnceAnim(X-16, Y-16, Anim);
          Anim.Free();
        end;
        if Send and g_Game_IsServer and g_Game_IsNet then
          MH_SEND_Effect(X-16, Y-16, Byte(not Silent), NET_GFX_RESPAWN);
      end;
      EFFECT_FIRE: begin
        if g_Frames_Get(FramesID, 'FRAMES_FIRE') then
        begin
          Anim := TAnimation.Create(FramesID, False, 4);
          if not Silent then
            g_Sound_PlayExAt('SOUND_FIRE', X, Y);
          g_GFX_OnceAnim(X-32, Y-128, Anim);
          Anim.Free();
        end;
        if Send and g_Game_IsServer and g_Game_IsNet then
          MH_SEND_Effect(X-32, Y-128, Byte(not Silent), NET_GFX_FIRE);
      end;
    end;
end;

function ActivateTrigger(var Trigger: TTrigger; actType: Byte): Boolean;
var
  animonce: Boolean;
  p: TPlayer;
  m: TMonster;
  i, k, wx, wy, xd, yd: Integer;
  iid: LongWord;
  coolDown: Boolean;
  pAngle: Real;
  FramesID: DWORD;
  Anim: TAnimation;
  UIDType: Byte;
  TargetUID: Word;
  msg: string;
begin
  Result := False;
  if g_Game_IsClient then
    Exit;

  if not Trigger.Enabled then
    Exit;
  if (Trigger.TimeOut <> 0) and (actType <> ACTIVATE_CUSTOM) then
    Exit;
  if gLMSRespawn = LMS_RESPAWN_WARMUP then
    Exit;

  animonce := False;

  coolDown := (actType <> 0);

  with Trigger do
  begin
    case TriggerType of
      TRIGGER_EXIT:
        begin
          g_Sound_PlayEx('SOUND_GAME_SWITCH0');
          if g_Game_IsNet then MH_SEND_Sound(X, Y, 'SOUND_GAME_SWITCH0');
          gExitByTrigger := True;
          g_Game_ExitLevel(Data.MapName);
          TimeOut := 18;
          Result := True;

          Exit;
        end;

      TRIGGER_TELEPORT:
        begin
          case g_GetUIDType(ActivateUID) of
            UID_PLAYER:
              begin
                p := g_Player_Get(ActivateUID);
                if p = nil then
                  Exit;

                if Data.d2d_teleport then
                  begin
                    if p.TeleportTo(Data.TargetPoint.X-(p.Obj.Rect.Width div 2),
                                    Data.TargetPoint.Y-p.Obj.Rect.Height,
                                    Data.silent_teleport,
                                    Data.TlpDir) then
                      Result := True;
                  end
                else
                  if p.TeleportTo(Data.TargetPoint.X,
                                  Data.TargetPoint.Y,
                                  Data.silent_teleport,
                                  Data.TlpDir) then
                    Result := True;
              end;

            UID_MONSTER:
              begin
                m := g_Monsters_Get(ActivateUID);
                if m = nil then
                  Exit;

                if Data.d2d_teleport then
                  begin
                    if m.TeleportTo(Data.TargetPoint.X-(m.Obj.Rect.Width div 2),
                                    Data.TargetPoint.Y-m.Obj.Rect.Height,
                                    Data.silent_teleport,
                                    Data.TlpDir) then
                      Result := True;
                  end
                else
                  if m.TeleportTo(Data.TargetPoint.X,
                                  Data.TargetPoint.Y,
                                  Data.silent_teleport,
                                  Data.TlpDir) then
                    Result := True;
              end;
          end;

          TimeOut := 0;
        end;

      TRIGGER_OPENDOOR:
        begin
          Result := OpenDoor(Data.PanelID, Data.NoSound, Data.d2d_doors);
          TimeOut := 0;
        end;

      TRIGGER_CLOSEDOOR:
        begin
          Result := CloseDoor(Data.PanelID, Data.NoSound, Data.d2d_doors);
          TimeOut := 0;
        end;

      TRIGGER_DOOR, TRIGGER_DOOR5:
        begin
          if Data.PanelID <> -1 then
          begin
            if gWalls[Data.PanelID].Enabled then
              begin
                Result := OpenDoor(Data.PanelID, Data.NoSound, Data.d2d_doors);

                if TriggerType = TRIGGER_DOOR5 then
                  DoorTime := 180;
              end
            else
              Result := CloseDoor(Data.PanelID, Data.NoSound, Data.d2d_doors);

            if Result then
              TimeOut := 18;
          end;
        end;

      TRIGGER_CLOSETRAP, TRIGGER_TRAP:
        begin
          CloseTrap(Data.PanelID, Data.NoSound, Data.d2d_doors);

          if TriggerType = TRIGGER_TRAP then
            begin
              DoorTime := 40;
              TimeOut := 76;
            end
          else
            begin
              DoorTime := -1;
              TimeOut := 0;
            end;

          Result := True;
        end;

      TRIGGER_PRESS, TRIGGER_ON, TRIGGER_OFF, TRIGGER_ONOFF:
        begin
          PressCount := PressCount + 1;
          
          if PressTime = -1 then
            PressTime := Data.Wait;

          if coolDown then
            TimeOut := 18
          else
            TimeOut := 0;
          Result := True;
        end;

      TRIGGER_SECRET:
        if g_GetUIDType(ActivateUID) = UID_PLAYER then
        begin
          Enabled := False;
          Result := True;
          if gLMSRespawn = LMS_RESPAWN_NONE then
          begin
            g_Player_Get(ActivateUID).GetSecret();
            Inc(gCoopSecretsFound);
            if g_Game_IsNet then MH_SEND_GameStats();
          end;
        end;

      TRIGGER_LIFTUP:
        begin
          Result := SetLift(Data.PanelID, 0, Data.NoSound, Data.d2d_doors);
          TimeOut := 0;

          if (not Data.NoSound) and Result then begin
            g_Sound_PlayExAt('SOUND_GAME_SWITCH0',
                             X + (Width div 2),
                             Y + (Height div 2));
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_Sound(X + (Width div 2),
                            Y + (Height div 2),
                            'SOUND_GAME_SWITCH0');
          end;
        end;

      TRIGGER_LIFTDOWN:
        begin
          Result := SetLift(Data.PanelID, 1, Data.NoSound, Data.d2d_doors);
          TimeOut := 0;

          if (not Data.NoSound) and Result then begin
            g_Sound_PlayExAt('SOUND_GAME_SWITCH0',
                             X + (Width div 2),
                             Y + (Height div 2));
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_Sound(X + (Width div 2),
                            Y + (Height div 2),
                            'SOUND_GAME_SWITCH0');
          end;
        end;

      TRIGGER_LIFT:
        begin
          Result := SetLift(Data.PanelID, 3, Data.NoSound, Data.d2d_doors);

          if Result then
          begin
            TimeOut := 18;

            if (not Data.NoSound) and Result then begin
              g_Sound_PlayExAt('SOUND_GAME_SWITCH0',
                               X + (Width div 2),
                               Y + (Height div 2));
              if g_Game_IsServer and g_Game_IsNet then
                MH_SEND_Sound(X + (Width div 2),
                              Y + (Height div 2),
                              'SOUND_GAME_SWITCH0');
            end;
          end;
        end;

      TRIGGER_TEXTURE:
        begin
          if ByteBool(Data.ActivateOnce) then
            begin
              Enabled := False;
              TriggerType := TRIGGER_NONE;
            end
          else
            if coolDown then
              TimeOut := 6
            else
              TimeOut := 0;

          animonce := Data.AnimOnce;
          Result := True;
        end;

      TRIGGER_SOUND:
        begin
          if Sound <> nil then
          begin
            if Data.SoundSwitch and Sound.IsPlaying() then
              begin // ����� ���������, ���� �����
                Sound.Stop();
                SoundPlayCount := 0;
                Result := True;
              end
            else // (not Data.SoundSwitch) or (not Sound.IsPlaying())
              if (Data.PlayCount > 0) or (not Sound.IsPlaying()) then
                begin
                  if Data.PlayCount > 0 then
                    SoundPlayCount := Data.PlayCount
                  else // 0 - ������ ����������
                    SoundPlayCount := 1;
                  Result := True;
                end;
            if g_Game_IsNet then MH_SEND_TriggerSound(Trigger);
          end;
        end;

      TRIGGER_SPAWNMONSTER:
        if (Data.MonType in [MONSTER_DEMON..MONSTER_MAN]) then
        begin
          Result := False;
          if (Data.MonDelay > 0) and (actType <> ACTIVATE_CUSTOM) then
          begin
            AutoSpawn := not AutoSpawn;
            SpawnCooldown := 0;
            // ����������� ���������� - ������ ��������
            Result := True;
          end;

          if ((Data.MonDelay = 0) and (actType <> ACTIVATE_CUSTOM))
          or ((Data.MonDelay > 0) and (actType = ACTIVATE_CUSTOM)) then
            for k := 1 to Data.MonCount do
            begin
              if (actType = ACTIVATE_CUSTOM) and (Data.MonDelay > 0) then
                SpawnCooldown := Data.MonDelay;
              if (Data.MonMax > 0) and (SpawnedCount >= Data.MonMax) then
                Break;

              i := g_Monsters_Create(Data.MonType,
                     Data.MonPos.X, Data.MonPos.Y,
                     TDirection(Data.MonDir), True);

              Result := True;

            // ��������:
              if (Data.MonHealth > 0) then
                gMonsters[i].SetHealth(Data.MonHealth);
            // ������������� ���������:
              gMonsters[i].MonsterBehaviour := Data.MonBehav;
            // ���� ������ ����, ���� ����:
              if Data.MonActive then
                gMonsters[i].WakeUp();
              gMonsters[i].FNoRespawn := True;

              if Data.MonType <> MONSTER_BARREL then Inc(gTotalMonsters);

              if g_Game_IsNet then
              begin
                SetLength(gMonstersSpawned, Length(gMonstersSpawned)+1);
                gMonstersSpawned[High(gMonstersSpawned)] := gMonsters[i].UID;
              end;

              if Data.MonMax > 0 then
              begin
                gMonsters[i].SpawnTrigger := ID;
                Inc(SpawnedCount);
              end;

              case Data.MonEffect of
                EFFECT_TELEPORT: begin
                  if g_Frames_Get(FramesID, 'FRAMES_TELEPORT') then
                  begin
                    Anim := TAnimation.Create(FramesID, False, 3);
                    g_Sound_PlayExAt('SOUND_GAME_TELEPORT', Data.MonPos.X, Data.MonPos.Y);
                    g_GFX_OnceAnim(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-32,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+(gMonsters[i].Obj.Rect.Height div 2)-32, Anim);
                    Anim.Free();
                  end;
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_Effect(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-32,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+(gMonsters[i].Obj.Rect.Height div 2)-32, 1,
                                   NET_GFX_TELE);
                end;
                EFFECT_RESPAWN: begin
                  if g_Frames_Get(FramesID, 'FRAMES_ITEM_RESPAWN') then
                  begin
                    Anim := TAnimation.Create(FramesID, False, 4);
                    g_Sound_PlayExAt('SOUND_ITEM_RESPAWNITEM', Data.MonPos.X, Data.MonPos.Y);
                    g_GFX_OnceAnim(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-16,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+(gMonsters[i].Obj.Rect.Height div 2)-16, Anim);
                    Anim.Free();
                  end;
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_Effect(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-16,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+(gMonsters[i].Obj.Rect.Height div 2)-16, 1,
                                   NET_GFX_RESPAWN);
                end;
                EFFECT_FIRE: begin
                  if g_Frames_Get(FramesID, 'FRAMES_FIRE') then
                  begin
                    Anim := TAnimation.Create(FramesID, False, 4);
                    g_Sound_PlayExAt('SOUND_FIRE', Data.MonPos.X, Data.MonPos.Y);
                    g_GFX_OnceAnim(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-32,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+gMonsters[i].Obj.Rect.Height-128, Anim);
                    Anim.Free();
                  end;
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_Effect(gMonsters[i].Obj.X+gMonsters[i].Obj.Rect.X+(gMonsters[i].Obj.Rect.Width div 2)-32,
                                   gMonsters[i].Obj.Y+gMonsters[i].Obj.Rect.Y+gMonsters[i].Obj.Rect.Height-128, 1,
                                   NET_GFX_FIRE);
                end;
              end;

              if g_Game_IsNet then
                MH_SEND_MonsterSpawn(gMonsters[i].UID);
            end;
          if g_Game_IsNet then
          begin
            MH_SEND_GameStats();
            MH_SEND_CoopStats();
          end;

          if coolDown then
            TimeOut := 18
          else
            TimeOut := 0;
          // ���� ����������� �������������, �� ������ ��������
          if actType = ACTIVATE_CUSTOM then
            Result := False;
        end;

      TRIGGER_SPAWNITEM:
        if (Data.ItemType in [ITEM_MEDKIT_SMALL..ITEM_MAX]) then
        begin
          Result := False;
          if (Data.ItemDelay > 0) and (actType <> ACTIVATE_CUSTOM) then
          begin
            AutoSpawn := not AutoSpawn;
            SpawnCooldown := 0;
            // ����������� ���������� - ������ ��������
            Result := True;
          end;

          if ((Data.ItemDelay = 0) and (actType <> ACTIVATE_CUSTOM))
          or ((Data.ItemDelay > 0) and (actType = ACTIVATE_CUSTOM)) then
            if (not Data.ItemOnlyDM) or
               (gGameSettings.GameMode in [GM_DM, GM_TDM, GM_CTF]) then
              for k := 1 to Data.ItemCount do
              begin
                if (actType = ACTIVATE_CUSTOM) and (Data.ItemDelay > 0) then
                  SpawnCooldown := Data.ItemDelay;
                if (Data.ItemMax > 0) and (SpawnedCount >= Data.ItemMax) then
                  Break;

                iid := g_Items_Create(Data.ItemPos.X, Data.ItemPos.Y,
                  Data.ItemType, Data.ItemFalls, False, True);

                Result := True;

                if Data.ItemMax > 0 then
                begin
                  gItems[iid].SpawnTrigger := ID;
                  Inc(SpawnedCount);
                end;

                case Data.ItemEffect of
                  EFFECT_TELEPORT: begin
                    if g_Frames_Get(FramesID, 'FRAMES_TELEPORT') then
                    begin
                      Anim := TAnimation.Create(FramesID, False, 3);
                      g_Sound_PlayExAt('SOUND_GAME_TELEPORT', Data.ItemPos.X, Data.ItemPos.Y);
                      g_GFX_OnceAnim(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-32,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+(gItems[iid].Obj.Rect.Height div 2)-32, Anim);
                      Anim.Free();
                    end;
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_Effect(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-32,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+(gItems[iid].Obj.Rect.Height div 2)-32, 1,
                                     NET_GFX_TELE);
                  end;
                  EFFECT_RESPAWN: begin
                    if g_Frames_Get(FramesID, 'FRAMES_ITEM_RESPAWN') then
                    begin
                      Anim := TAnimation.Create(FramesID, False, 4);
                      g_Sound_PlayExAt('SOUND_ITEM_RESPAWNITEM', Data.ItemPos.X, Data.ItemPos.Y);
                      g_GFX_OnceAnim(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-16,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+(gItems[iid].Obj.Rect.Height div 2)-16, Anim);
                      Anim.Free();
                    end;
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_Effect(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-16,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+(gItems[iid].Obj.Rect.Height div 2)-16, 1,
                                     NET_GFX_RESPAWN);
                  end;
                  EFFECT_FIRE: begin
                    if g_Frames_Get(FramesID, 'FRAMES_FIRE') then
                    begin
                      Anim := TAnimation.Create(FramesID, False, 4);
                      g_Sound_PlayExAt('SOUND_FIRE', Data.ItemPos.X, Data.ItemPos.Y);
                      g_GFX_OnceAnim(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-32,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+gItems[iid].Obj.Rect.Height-128, Anim);
                      Anim.Free();
                    end;
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_Effect(gItems[iid].Obj.X+gItems[iid].Obj.Rect.X+(gItems[iid].Obj.Rect.Width div 2)-32,
                                     gItems[iid].Obj.Y+gItems[iid].Obj.Rect.Y+gItems[iid].Obj.Rect.Height-128, 1,
                                     NET_GFX_FIRE);
                  end;
                end;

                if g_Game_IsNet then
                  MH_SEND_ItemSpawn(True, iid);
              end;

          if coolDown then
            TimeOut := 18
          else
            TimeOut := 0;
          // ���� ����������� �������������, �� ������ ��������
          if actType = ACTIVATE_CUSTOM then
            Result := False;
        end;

      TRIGGER_MUSIC:
        begin
        // ������ ������, ���� ���� �� ���:
          if (Trigger.Data.MusicName <> '') then
          begin
            gMusic.SetByName(Trigger.Data.MusicName);
            gMusic.SpecPause := True;
            gMusic.Play();
          end;

          if Trigger.Data.MusicAction = 1 then
            begin // ��������
              if gMusic.SpecPause then // ���� �� ����� => ������
                gMusic.SpecPause := False
              else // ������ => �������
                gMusic.SetPosition(0);
            end
          else // ���������
            begin
            // �����:
              gMusic.SpecPause := True;
            end;

          if coolDown then
            TimeOut := 36
          else
            TimeOut := 0;
          Result := True;
          if g_Game_IsNet then MH_SEND_TriggerMusic;
        end;

      TRIGGER_PUSH:
        begin
          case g_GetUIDType(ActivateUID) of
            UID_PLAYER:
              begin
                p := g_Player_Get(ActivateUID);
                if p = nil then
                  Exit;
                  
                if Data.ResetVel then
                begin
                  p.GameVelX := 0;
                  p.GameVelY := 0;
                  p.GameAccelX := 0;
                  p.GameAccelY := 0;
                end;

                pAngle := -DegToRad(Data.PushAngle);
                p.Push(Floor(Cos(pAngle)*Data.PushForce),
                       Floor(Sin(pAngle)*Data.PushForce));
              end;

            UID_MONSTER:
              begin
                m := g_Monsters_Get(ActivateUID);
                if m = nil then
                  Exit;
                if Data.ResetVel then
                begin
                  m.GameVelX := 0;
                  m.GameVelY := 0;
                  m.GameAccelX := 0;
                  m.GameAccelY := 0;
                end;

                pAngle := -DegToRad(Data.PushAngle);
                m.Push(Floor(Cos(pAngle)*Data.PushForce),
                       Floor(Sin(pAngle)*Data.PushForce));
              end;
          end;

          TimeOut := 0;
          Result := True;
        end;

      TRIGGER_SCORE:
        begin
          Result := False;
          // ��������� ��� ������ ����
          if (Data.ScoreAction in [0..1]) and (Data.ScoreCount > 0) then
          begin
            // ����� ��� ����� �������
            if (Data.ScoreTeam in [0..1]) and (g_GetUIDType(ActivateUID) = UID_PLAYER) then
            begin
              p := g_Player_Get(ActivateUID);
              if ((Data.ScoreAction = 0) and (Data.ScoreTeam = 0) and (p.Team = TEAM_RED))
              or ((Data.ScoreAction = 0) and (Data.ScoreTeam = 1) and (p.Team = TEAM_BLUE)) then
              begin
                Inc(gTeamStat[TEAM_RED].Goals, Data.ScoreCount); // Red Scores

                if Data.ScoreCon then
                  if Data.ScoreTeam = 0 then
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_OWN], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '+r');
                  end else
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_ENEMY], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '+re');
                  end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_ADD], [AnsiUpperCase(_lc[I_GAME_TEAM_RED])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, TEAM_RED);
                end;
              end;
              if ((Data.ScoreAction = 1) and (Data.ScoreTeam = 0) and (p.Team = TEAM_RED))
              or ((Data.ScoreAction = 1) and (Data.ScoreTeam = 1) and (p.Team = TEAM_BLUE)) then
              begin
                Dec(gTeamStat[TEAM_RED].Goals, Data.ScoreCount); // Red Fouls

                if Data.ScoreCon then
                  if Data.ScoreTeam = 0 then
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_OWN], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '-r');
                  end else
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_ENEMY], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '-re');
                  end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_SUB], [AnsiUpperCase(_lc[I_GAME_TEAM_RED])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, -TEAM_RED);
                end;
              end;
              if ((Data.ScoreAction = 0) and (Data.ScoreTeam = 0) and (p.Team = TEAM_BLUE))
              or ((Data.ScoreAction = 0) and (Data.ScoreTeam = 1) and (p.Team = TEAM_RED)) then
              begin
                Inc(gTeamStat[TEAM_BLUE].Goals, Data.ScoreCount); // Blue Scores

                if Data.ScoreCon then
                  if Data.ScoreTeam = 0 then
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_OWN], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '+b');
                  end else
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_ENEMY], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '+be');
                  end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_ADD], [AnsiUpperCase(_lc[I_GAME_TEAM_BLUE])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, TEAM_BLUE);
                end;
              end;
              if ((Data.ScoreAction = 1) and (Data.ScoreTeam = 0) and (p.Team = TEAM_BLUE))
              or ((Data.ScoreAction = 1) and (Data.ScoreTeam = 1) and (p.Team = TEAM_RED)) then
              begin
                Dec(gTeamStat[TEAM_BLUE].Goals, Data.ScoreCount); // Blue Fouls

                if Data.ScoreCon then
                  if Data.ScoreTeam = 0 then
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_OWN], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '-b');
                  end else
                  begin
                    g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_ENEMY], [p.Name, Data.ScoreCount, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                    if g_Game_IsServer and g_Game_IsNet then
                      MH_SEND_GameEvent(NET_EV_SCORE, p.UID or (Data.ScoreCount shl 16), '-be');
                  end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_SUB], [AnsiUpperCase(_lc[I_GAME_TEAM_BLUE])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, -TEAM_BLUE);
                end;
              end;
              Result := (p.Team = TEAM_RED) or (p.Team = TEAM_BLUE);
            end;
            // �����-�� ���������� �������
            if Data.ScoreTeam in [2..3] then
            begin
              if (Data.ScoreAction = 0) and (Data.ScoreTeam = 2) then
              begin
                Inc(gTeamStat[TEAM_RED].Goals, Data.ScoreCount); // Red Scores

                if Data.ScoreCon then
                begin
                  g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_TEAM], [_lc[I_PLAYER_SCORE_RED], Data.ScoreCount]), True);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE, Data.ScoreCount shl 16, '+tr');
                end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_ADD], [AnsiUpperCase(_lc[I_GAME_TEAM_RED])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, TEAM_RED);
                end;
              end;
              if (Data.ScoreAction = 1) and (Data.ScoreTeam = 2) then
              begin
                Dec(gTeamStat[TEAM_RED].Goals, Data.ScoreCount); // Red Fouls

                if Data.ScoreCon then
                begin
                  g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_TEAM], [_lc[I_PLAYER_SCORE_RED], Data.ScoreCount]), True);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE, Data.ScoreCount shl 16, '-tr');
                end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_SUB], [AnsiUpperCase(_lc[I_GAME_TEAM_RED])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, -TEAM_RED);
                end;
              end;
              if (Data.ScoreAction = 0) and (Data.ScoreTeam = 3) then
              begin
                Inc(gTeamStat[TEAM_BLUE].Goals, Data.ScoreCount); // Blue Scores

                if Data.ScoreCon then
                begin
                  g_Console_Add(Format(_lc[I_PLAYER_SCORE_ADD_TEAM], [_lc[I_PLAYER_SCORE_BLUE], Data.ScoreCount]), True);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE, Data.ScoreCount shl 16, '+tb');
                end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_ADD], [AnsiUpperCase(_lc[I_GAME_TEAM_BLUE])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, TEAM_BLUE);
                end;
              end;
              if (Data.ScoreAction = 1) and (Data.ScoreTeam = 3) then
              begin
                Dec(gTeamStat[TEAM_BLUE].Goals, Data.ScoreCount); // Blue Fouls

                if Data.ScoreCon then
                begin
                  g_Console_Add(Format(_lc[I_PLAYER_SCORE_SUB_TEAM], [_lc[I_PLAYER_SCORE_BLUE], Data.ScoreCount]), True);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE, Data.ScoreCount shl 16, '-tb');
                end;

                if Data.ScoreMsg then
                begin
                  g_Game_Message(Format(_lc[I_MESSAGE_SCORE_SUB], [AnsiUpperCase(_lc[I_GAME_TEAM_BLUE])]), 108);
                  if g_Game_IsServer and g_Game_IsNet then
                    MH_SEND_GameEvent(NET_EV_SCORE_MSG, -TEAM_BLUE);
                end;
              end;
              Result := True;
            end;
          end;
          // �������
          if (Data.ScoreAction = 2) and (gGameSettings.GoalLimit > 0) then
          begin
            // ����� ��� ����� �������
            if (Data.ScoreTeam in [0..1]) and (g_GetUIDType(ActivateUID) = UID_PLAYER) then
            begin
              p := g_Player_Get(ActivateUID);
              if ((Data.ScoreTeam = 0) and (p.Team = TEAM_RED)) // Red Wins
              or ((Data.ScoreTeam = 1) and (p.Team = TEAM_BLUE)) then
                if gTeamStat[TEAM_RED].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_RED].Goals := gGameSettings.GoalLimit;

                  if Data.ScoreCon then
                    if Data.ScoreTeam = 0 then
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_OWN], [p.Name, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wr');
                    end else
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_ENEMY], [p.Name, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wre');
                    end;

                  Result := True;
                end;
              if ((Data.ScoreTeam = 0) and (p.Team = TEAM_BLUE)) // Blue Wins
              or ((Data.ScoreTeam = 1) and (p.Team = TEAM_RED)) then
                if gTeamStat[TEAM_BLUE].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_BLUE].Goals := gGameSettings.GoalLimit;

                  if Data.ScoreCon then
                    if Data.ScoreTeam = 0 then
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_OWN], [p.Name, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wb');
                    end else
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_ENEMY], [p.Name, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wbe');
                    end;

                  Result := True;
                end;
            end;
            // �����-�� ���������� �������
            if Data.ScoreTeam in [2..3] then
            begin
              if Data.ScoreTeam = 2 then // Red Wins
                if gTeamStat[TEAM_RED].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_RED].Goals := gGameSettings.GoalLimit;
                  Result := True;
                end;
              if Data.ScoreTeam = 3 then // Blue Wins
                if gTeamStat[TEAM_BLUE].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_BLUE].Goals := gGameSettings.GoalLimit;
                  Result := True;
                end;
            end;
          end;
          // ��������
          if (Data.ScoreAction = 3) and (gGameSettings.GoalLimit > 0) then
          begin
            // ����� ��� ����� �������
            if (Data.ScoreTeam in [0..1]) and (g_GetUIDType(ActivateUID) = UID_PLAYER) then
            begin
              p := g_Player_Get(ActivateUID);
              if ((Data.ScoreTeam = 0) and (p.Team = TEAM_BLUE)) // Red Wins
              or ((Data.ScoreTeam = 1) and (p.Team = TEAM_RED)) then
                if gTeamStat[TEAM_RED].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_RED].Goals := gGameSettings.GoalLimit;

                  if Data.ScoreCon then
                    if Data.ScoreTeam = 0 then
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_ENEMY], [p.Name, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wre');
                    end else
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_OWN], [p.Name, _lc[I_PLAYER_SCORE_TO_RED]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wr');
                    end;

                  Result := True;
                end;
              if ((Data.ScoreTeam = 0) and (p.Team = TEAM_RED)) // Blue Wins
              or ((Data.ScoreTeam = 1) and (p.Team = TEAM_BLUE)) then
                if gTeamStat[TEAM_BLUE].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_BLUE].Goals := gGameSettings.GoalLimit;

                  if Data.ScoreCon then
                    if Data.ScoreTeam = 0 then
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_ENEMY], [p.Name, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wbe');
                    end else
                    begin
                      g_Console_Add(Format(_lc[I_PLAYER_SCORE_WIN_OWN], [p.Name, _lc[I_PLAYER_SCORE_TO_BLUE]]), True);
                      if g_Game_IsServer and g_Game_IsNet then
                        MH_SEND_GameEvent(NET_EV_SCORE, p.UID, 'wb');
                    end;

                  Result := True;
                end;
            end;
            // �����-�� ���������� �������
            if Data.ScoreTeam in [2..3] then
            begin
              if Data.ScoreTeam = 3 then // Red Wins
                if gTeamStat[TEAM_RED].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_RED].Goals := gGameSettings.GoalLimit;
                  Result := True;
                end;
              if Data.ScoreTeam = 2 then // Blue Wins
                if gTeamStat[TEAM_BLUE].Goals < SmallInt(gGameSettings.GoalLimit) then
                begin
                  gTeamStat[TEAM_BLUE].Goals := gGameSettings.GoalLimit;
                  Result := True;
                end;
            end;
          end;
          if Result then begin
            if coolDown then
              TimeOut := 18
            else
              TimeOut := 0;
            if g_Game_IsServer and g_Game_IsNet then
              MH_SEND_GameStats;
          end;
        end;

      TRIGGER_MESSAGE:
        begin
          msg := b_Text_Format(Data.MessageText);
          case Data.MessageSendTo of
            0: // activator
              begin
                if g_GetUIDType(ActivateUID) = UID_PLAYER then
                begin
                  if g_Game_IsWatchedPlayer(ActivateUID) then
                  begin
                    if Data.MessageKind = 0 then
                      g_Console_Add(msg, True)
                    else if Data.MessageKind = 1 then
                      g_Game_Message(msg, Data.MessageTime);
                  end
                  else
                  begin
                    p := g_Player_Get(ActivateUID);
                    if g_Game_IsNet and (p.FClientID >= 0) then
                      if Data.MessageKind = 0 then
                        MH_SEND_Chat(msg, NET_CHAT_SYSTEM, p.FClientID)
                      else if Data.MessageKind = 1 then
                        MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg, p.FClientID);
                  end;
                end;
              end;

            1: // activator's team
              begin
                if g_GetUIDType(ActivateUID) = UID_PLAYER then
                begin
                  p := g_Player_Get(ActivateUID);
                  if g_Game_IsWatchedTeam(p.Team) then
                    if Data.MessageKind = 0 then
                      g_Console_Add(msg, True)
                    else if Data.MessageKind = 1 then
                      g_Game_Message(msg, Data.MessageTime);

                  if g_Game_IsNet then
                  begin
                    for i := Low(gPlayers) to High(gPlayers) do
                      if (gPlayers[i].Team = p.Team) and (gPlayers[i].FClientID >= 0) then
                        if Data.MessageKind = 0 then
                          MH_SEND_Chat(msg, NET_CHAT_SYSTEM, gPlayers[i].FClientID)
                        else if Data.MessageKind = 1 then
                          MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg, gPlayers[i].FClientID);
                  end;
                end;
              end;

            2: // activator's enemy team
              begin
                if g_GetUIDType(ActivateUID) = UID_PLAYER then
                begin
                  p := g_Player_Get(ActivateUID);
                  if g_Game_IsWatchedTeam(p.Team) then
                    if Data.MessageKind = 0 then
                      g_Console_Add(msg, True)
                    else if Data.MessageKind = 1 then
                      g_Game_Message(msg, Data.MessageTime);

                  if g_Game_IsNet then
                  begin
                    for i := Low(gPlayers) to High(gPlayers) do
                      if (gPlayers[i].Team <> p.Team) and (gPlayers[i].FClientID >= 0) then
                        if Data.MessageKind = 0 then
                          MH_SEND_Chat(msg, NET_CHAT_SYSTEM, gPlayers[i].FClientID)
                        else if Data.MessageKind = 1 then
                          MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg, gPlayers[i].FClientID);
                  end;
                end;
              end;

            3: // red team
              begin
                if g_Game_IsWatchedTeam(TEAM_RED) then
                  if Data.MessageKind = 0 then
                    g_Console_Add(msg, True)
                  else if Data.MessageKind = 1 then
                    g_Game_Message(msg, Data.MessageTime);

                if g_Game_IsNet then
                begin
                  for i := Low(gPlayers) to High(gPlayers) do
                    if (gPlayers[i].Team = TEAM_RED) and (gPlayers[i].FClientID >= 0) then
                      if Data.MessageKind = 0 then
                        MH_SEND_Chat(msg, NET_CHAT_SYSTEM, gPlayers[i].FClientID)
                      else if Data.MessageKind = 1 then
                        MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg, gPlayers[i].FClientID);
                end;
              end;

            4: // blue team
              begin
                if g_Game_IsWatchedTeam(TEAM_BLUE) then
                  if Data.MessageKind = 0 then
                    g_Console_Add(msg, True)
                  else if Data.MessageKind = 1 then
                    g_Game_Message(msg, Data.MessageTime);

                if g_Game_IsNet then
                begin
                  for i := Low(gPlayers) to High(gPlayers) do
                    if (gPlayers[i].Team = TEAM_BLUE) and (gPlayers[i].FClientID >= 0) then
                      if Data.MessageKind = 0 then
                        MH_SEND_Chat(msg, NET_CHAT_SYSTEM, gPlayers[i].FClientID)
                      else if Data.MessageKind = 1 then
                        MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg, gPlayers[i].FClientID);
                end;
              end;

            5: // everyone
              begin
                if Data.MessageKind = 0 then
                  g_Console_Add(msg, True)
                else if Data.MessageKind = 1 then
                  g_Game_Message(msg, Data.MessageTime);

                if g_Game_IsNet then
                begin
                  if Data.MessageKind = 0 then
                    MH_SEND_Chat(msg, NET_CHAT_SYSTEM)
                  else if Data.MessageKind = 1 then
                    MH_SEND_GameEvent(NET_EV_BIGTEXT, Data.MessageTime, msg);
                end;
              end;
          end;
          TimeOut := 18;
        end;

      TRIGGER_DAMAGE, TRIGGER_HEALTH:
        begin
          Result := False;
          UIDType := g_GetUIDType(ActivateUID);
          if (UIDType = UID_PLAYER) or (UIDType = UID_MONSTER) then
          begin
            Result := True;
            k := -1;
            if coolDown then
            begin
              // ����������, ����������� �� �� ���� ������
              for i := 0 to High(Activators) do
                if Activators[i].UID = ActivateUID then
                begin
                  k := i;
                  Break;
                end;
              if k = -1 then
              begin // ����� ��� �������
                // ���������� ���
                SetLength(Activators, Length(Activators) + 1);
                k := High(Activators);
                Activators[k].UID := ActivateUID;
              end else
              begin // ��� ������ ���
                // ���� �������� ��������, �� �� �� ��� � ���� ���������, ��� ��� �����
                if (Data.DamageInterval = 0) and (Activators[k].TimeOut > 0) then
                  Activators[k].TimeOut := 65535;
                // ������� ������ - ��������
                Result := Activators[k].TimeOut = 0;
              end;
            end;

            if Result then
            begin
              case UIDType of
                UID_PLAYER:
                  begin
                    p := g_Player_Get(ActivateUID);
                    if p = nil then
                      Exit;

                    // ������� ���� ������
                    if (TriggerType = TRIGGER_DAMAGE) and (Data.DamageValue > 0) then
                      p.Damage(Data.DamageValue, 0, 0, 0, HIT_SOME);

                    // ����� ������
                    if (TriggerType = TRIGGER_HEALTH) and (Data.HealValue > 0) then
                      if p.Heal(Data.HealValue, not Data.HealMax) and (not Data.HealSilent) then
                      begin
                        g_Sound_PlayExAt('SOUND_ITEM_GETITEM', p.Obj.X, p.Obj.Y);
                        if g_Game_IsServer and g_Game_IsNet then
                          MH_SEND_Sound(p.Obj.X, p.Obj.Y, 'SOUND_ITEM_GETITEM');
                      end;
                  end;

                UID_MONSTER:
                  begin
                    m := g_Monsters_Get(ActivateUID);
                    if m = nil then
                      Exit;

                    // ������� ���� �������
                    if (TriggerType = TRIGGER_DAMAGE) and (Data.DamageValue > 0) then
                      m.Damage(Data.DamageValue, 0, 0, 0, HIT_SOME);

                    // ����� �������
                    if (TriggerType = TRIGGER_HEALTH) and (Data.HealValue > 0) then
                      if m.Heal(Data.HealValue) and (not Data.HealSilent) then
                      begin
                        g_Sound_PlayExAt('SOUND_ITEM_GETITEM', m.Obj.X, m.Obj.Y);
                        if g_Game_IsServer and g_Game_IsNet then
                          MH_SEND_Sound(m.Obj.X, m.Obj.Y, 'SOUND_ITEM_GETITEM');
                      end;
                  end;
              end;
              // ��������� ����� ���������� �����������
              if TriggerType = TRIGGER_DAMAGE then
                i := Data.DamageInterval
              else
                i := Data.HealInterval;
              if coolDown then
                if i > 0 then
                  Activators[k].TimeOut := i
                else
                  Activators[k].TimeOut := 65535;
            end;
          end;
          TimeOut := 0;
        end;

      TRIGGER_SHOT:
        begin
          if ShotSightTime > 0 then
            Exit;

          wx := Data.ShotPos.X;
          wy := Data.ShotPos.Y;
          pAngle := -DegToRad(Data.ShotAngle);
          xd := wx + Round(Cos(pAngle) * 32.0);
          yd := wy + Round(Sin(pAngle) * 32.0);
          TargetUID := 0;

          case Data.ShotTarget of
            TRIGGER_SHOT_TARGET_MON: // monsters
              if gMonsters <> nil then
                for i := Low(gMonsters) to High(gMonsters) do
                  if (gMonsters[i] <> nil) and gMonsters[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gMonsters[i].Obj))) then
                  begin
                    xd := gMonsters[i].GameX + gMonsters[i].Obj.Rect.Width div 2;
                    yd := gMonsters[i].GameY + gMonsters[i].Obj.Rect.Height div 2;
                    TargetUID := gMonsters[i].UID;
                    break;
                  end;

            TRIGGER_SHOT_TARGET_PLR: // players
              if gPlayers <> nil then
                for i := Low(gPlayers) to High(gPlayers) do
                  if (gPlayers[i] <> nil) and gPlayers[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gPlayers[i].Obj))) then
                  begin
                    xd := gPlayers[i].GameX + PLAYER_RECT_CX;
                    yd := gPlayers[i].GameY + PLAYER_RECT_CY;
                    TargetUID := gPlayers[i].UID;
                    break;
                  end;

            TRIGGER_SHOT_TARGET_RED: // red team
              if gPlayers <> nil then
                for i := Low(gPlayers) to High(gPlayers) do
                  if (gPlayers[i] <> nil) and gPlayers[i].Live and
                     (gPlayers[i].Team = TEAM_RED) and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gPlayers[i].Obj))) then
                  begin
                    xd := gPlayers[i].GameX + PLAYER_RECT_CX;
                    yd := gPlayers[i].GameY + PLAYER_RECT_CY;
                    TargetUID := gPlayers[i].UID;
                    break;
                  end;

            TRIGGER_SHOT_TARGET_BLUE: // blue team
              if gPlayers <> nil then
                for i := Low(gPlayers) to High(gPlayers) do
                  if (gPlayers[i] <> nil) and gPlayers[i].Live and
                     (gPlayers[i].Team = TEAM_BLUE) and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gPlayers[i].Obj))) then
                  begin
                    xd := gPlayers[i].GameX + PLAYER_RECT_CX;
                    yd := gPlayers[i].GameY + PLAYER_RECT_CY;
                    TargetUID := gPlayers[i].UID;
                    break;
                  end;

            TRIGGER_SHOT_TARGET_MONPLR: // monsters then players
            begin
              if gMonsters <> nil then
                for i := Low(gMonsters) to High(gMonsters) do
                  if (gMonsters[i] <> nil) and gMonsters[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gMonsters[i].Obj))) then
                  begin
                    xd := gMonsters[i].GameX + gMonsters[i].Obj.Rect.Width div 2;
                    yd := gMonsters[i].GameY + gMonsters[i].Obj.Rect.Height div 2;
                    TargetUID := gMonsters[i].UID;
                    break;
                  end;
              if (TargetUID = 0) and (gPlayers <> nil) then
                for i := Low(gPlayers) to High(gPlayers) do
                  if (gPlayers[i] <> nil) and gPlayers[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gPlayers[i].Obj))) then
                  begin
                    xd := gPlayers[i].GameX + PLAYER_RECT_CX;
                    yd := gPlayers[i].GameY + PLAYER_RECT_CY;
                    TargetUID := gPlayers[i].UID;
                    break;
                  end;
            end;

            TRIGGER_SHOT_TARGET_PLRMON: // players then monsters
            begin
              if gPlayers <> nil then
                for i := Low(gPlayers) to High(gPlayers) do
                  if (gPlayers[i] <> nil) and gPlayers[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gPlayers[i].Obj))) then
                  begin
                    xd := gPlayers[i].GameX + PLAYER_RECT_CX;
                    yd := gPlayers[i].GameY + PLAYER_RECT_CY;
                    TargetUID := gPlayers[i].UID;
                    break;
                  end;
              if (TargetUID = 0) and (gMonsters <> nil) then
                for i := Low(gMonsters) to High(gMonsters) do
                  if (gMonsters[i] <> nil) and gMonsters[i].Live and
                     (Data.ShotAllMap or g_Obj_Collide(X, Y, Width, Height, @(gMonsters[i].Obj))) then
                  begin
                    xd := gMonsters[i].GameX + gMonsters[i].Obj.Rect.Width div 2;
                    yd := gMonsters[i].GameY + gMonsters[i].Obj.Rect.Height div 2;
                    TargetUID := gMonsters[i].UID;
                    break;
                  end;
            end;

            else TargetUID := ActivateUID;
          end;

          if (Data.ShotTarget = TRIGGER_SHOT_TARGET_NONE) or (TargetUID > 0) then
          begin
            Result := True;
            if (Data.ShotIntSight = 0) or
               (Data.ShotTarget = TRIGGER_SHOT_TARGET_NONE) or
               (TargetUID = ShotSightTarget) then
              MakeShot(Trigger, wx, wy, xd, yd, TargetUID)
            else
            begin
              ShotSightTime := Data.ShotIntSight;
              ShotSightTargetN := TargetUID;
              if Data.ShotType = TRIGGER_SHOT_BFG then
              begin
                g_Sound_PlayExAt('SOUND_WEAPON_STARTFIREBFG', wx, wy);
                if g_Game_IsNet and g_Game_IsServer then
                  MH_SEND_Sound(wx, wy, 'SOUND_WEAPON_STARTFIREBFG');
              end;
            end;
          end;

          TimeOut := Data.ShotWait + 1;
        end;

      TRIGGER_EFFECT:
        begin
          i := Data.FXCount;

          while i > 0 do
          begin
            case Data.FXPos of
              TRIGGER_EFFECT_POS_CENTER:
              begin
                wx := X + Width div 2;
                wy := Y + Height div 2;
              end;
              TRIGGER_EFFECT_POS_AREA:
              begin
                wx := X + Random(Width);
                wy := Y + Random(Height);
              end;
              else begin
                wx := X + Width div 2;
                wy := Y + Height div 2;
              end;
            end;
            xd := Data.FXVelX;
            yd := Data.FXVelY;
            if Data.FXSpreadL > 0 then xd := xd - Random(Data.FXSpreadL + 1);
            if Data.FXSpreadR > 0 then xd := xd + Random(Data.FXSpreadR + 1);
            if Data.FXSpreadU > 0 then yd := yd - Random(Data.FXSpreadU + 1);
            if Data.FXSpreadD > 0 then yd := yd + Random(Data.FXSpreadD + 1);
            MakeEffect(wx, wy, xd, yd,
                       Data.FXType, Data.FXSubType,
                       Data.FXColorR, Data.FXColorG, Data.FXColorB, True, False);
            Dec(i);
          end;
          TimeOut := Data.FXWait;
        end;
    end;
  end;

  if Result and (Trigger.TexturePanel <> -1) then
    g_Map_SwitchTexture(Trigger.TexturePanelType, Trigger.TexturePanel, IfThen(animonce, 2, 1));
end;

function g_Triggers_Create(Trigger: TTrigger): DWORD;
var
  find_id: DWORD;
  fn, mapw: String;
begin
// �� ��������� �����, ���� ���� ��� ������:
  if (Trigger.TriggerType = TRIGGER_EXIT) and
     (not LongBool(gGameSettings.Options and GAME_OPTION_ALLOWEXIT)) then
    Trigger.TriggerType := TRIGGER_NONE;

// ���� ������� ���������, �������� �������:
  if (Trigger.TriggerType = TRIGGER_SPAWNMONSTER) and
     (not LongBool(gGameSettings.Options and GAME_OPTION_MONSTERS)) and
     (gGameSettings.GameType <> GT_SINGLE) then
    Trigger.TriggerType := TRIGGER_NONE;

// ������� ���������� �������� �� �����:
  if Trigger.TriggerType = TRIGGER_SECRET then
    gSecretsCount := gSecretsCount + 1;

  find_id := FindTrigger();
  gTriggers[find_id] := Trigger;

  with gTriggers[find_id] do
  begin
    ID := find_id;
    // if this type of trigger exists both on the client and on the server
    // use an uniform numeration
    if Trigger.TriggerType = TRIGGER_SOUND then
    begin
      Inc(gTriggerClientID);
      ClientID := gTriggerClientID;
    end
    else
      ClientID := 0;
    TimeOut := 0;
    ActivateUID := 0;
    PlayerCollide := False;
    DoorTime := -1;
    PressTime := -1;
    PressCount := 0;
    SoundPlayCount := 0;
    Sound := nil;
    AutoSpawn := False;
    SpawnCooldown := 0;
    SpawnedCount := 0;
  end;

// ��������� ����, ���� ��� ������� "����":
  if (Trigger.TriggerType = TRIGGER_SOUND) and
     (Trigger.Data.SoundName <> '') then
  begin
  // ��� ��� ������ �����:
    if not g_Sound_Exists(Trigger.Data.SoundName) then
    begin
      g_ProcessResourceStr(Trigger.Data.SoundName, @fn, nil, nil);

      if fn = '' then
        begin // ���� � ����� � ������
          g_ProcessResourceStr(gMapInfo.Map, @mapw, nil, nil);
          fn := mapw + Trigger.Data.SoundName;
        end
      else // ���� � ��������� �����
        fn := GameDir + '\wads\' + Trigger.Data.SoundName;

      if not g_Sound_CreateWADEx(Trigger.Data.SoundName, fn) then
        g_FatalError(Format(_lc[I_GAME_ERROR_TR_SOUND], [fn, Trigger.Data.SoundName]));
    end;

  // ������� ������ �����:
    with gTriggers[find_id] do
    begin
      Sound := TPlayableSound.Create();
      if not Sound.SetByName(Trigger.Data.SoundName) then
      begin
        Sound.Free();
        Sound := nil;
      end;
    end;
  end;

// ��������� ������, ���� ��� ������� "������":
  if (Trigger.TriggerType = TRIGGER_MUSIC) and
     (Trigger.Data.MusicName <> '') then
  begin
  // ��� ��� ����� ������:
    if not g_Sound_Exists(Trigger.Data.MusicName) then
    begin
      g_ProcessResourceStr(Trigger.Data.MusicName, @fn, nil, nil);

      if fn = '' then
        begin // ������ � ����� � ������
          g_ProcessResourceStr(gMapInfo.Map, @mapw, nil, nil);
          fn := mapw + Trigger.Data.MusicName;
        end
      else // ������ � ����� � ������
        fn := GameDir+'\wads\'+Trigger.Data.MusicName;

      if not g_Sound_CreateWADEx(Trigger.Data.MusicName, fn, True) then
        g_FatalError(Format(_lc[I_GAME_ERROR_TR_SOUND], [fn, Trigger.Data.MusicName]));
    end;
  end;

// ��������� ������ �������� "������":
  if Trigger.TriggerType = TRIGGER_SHOT then
    with gTriggers[find_id] do
    begin
      ShotPanelTime := 0;
      ShotSightTime := 0;
      ShotSightTimeout := 0;
      ShotSightTarget := 0;
      ShotSightTargetN := 0;
      ShotAmmoCount := Trigger.Data.ShotAmmo;
      ShotReloadTime := 0;
    end;

  Result := find_id;
end;

procedure g_Triggers_Update();
var
  a, b, i: Integer;
  Affected: array of Integer;
begin
  if gTriggers = nil then
    Exit;

  for a := 0 to High(gTriggers) do
    with gTriggers[a] do
    // ���� �������:
      if TriggerType <> TRIGGER_NONE then
      begin
      // ��������� ����� �� �������� ����� (�������� �������):
        if DoorTime > 0 then
          DoorTime := DoorTime - 1;
      // ��������� ����� �������� ����� �������:
        if PressTime > 0 then
          PressTime := PressTime - 1;
      // ��������� ������� � ��������, ������� ����� ���������:
        if (TriggerType = TRIGGER_DAMAGE) or (TriggerType = TRIGGER_HEALTH) then
          for b := 0 to High(Activators) do
          begin
            // ��������� ����� �� ���������� �����������:
            if Activators[b].TimeOut > 0 then
              Dec(Activators[b].TimeOut)
            else
              Continue;
            // �������, ��� ������ ������� ���� �������� ��������
            if (Data.DamageInterval = 0) and (Activators[b].TimeOut < 65530) then
              Activators[b].TimeOut := 0;
          end;

      // ������������ ��������:
        if Enabled and AutoSpawn then
          if SpawnCooldown = 0 then
          begin
            // ���� ������ �����, ������� �������:
            if (TriggerType = TRIGGER_SPAWNMONSTER) and (Data.MonDelay > 0)  then
            begin
              ActivateUID := 0;
              ActivateTrigger(gTriggers[a], ACTIVATE_CUSTOM);
            end;
            // ���� ������ �����, ������� �������:
            if (TriggerType = TRIGGER_SPAWNITEM) and (Data.ItemDelay > 0) then
            begin
              ActivateUID := 0;
              ActivateTrigger(gTriggers[a], ACTIVATE_CUSTOM);
            end;
          end else // ��������� ����� ��������:
            Dec(SpawnCooldown);

      // ������������ ������� �������� "������":
        if TriggerType = TRIGGER_SHOT then
        begin
          if ShotPanelTime > 0 then
          begin
            Dec(ShotPanelTime);
            if ShotPanelTime = 0 then
              g_Map_SwitchTexture(ShotPanelType, Data.ShotPanelID);
          end;
          if ShotSightTime > 0 then
          begin
            Dec(ShotSightTime);
            if ShotSightTime = 0 then
              ShotSightTarget := ShotSightTargetN;
          end;
          if ShotSightTimeout > 0 then
          begin
            Dec(ShotSightTimeout);
            if ShotSightTimeout = 0 then
              ShotSightTarget := 0;
          end;
          if ShotReloadTime > 0 then
          begin
            Dec(ShotReloadTime);
            if ShotReloadTime = 0 then
              ShotAmmoCount := Data.ShotAmmo;
          end;
        end;

      // ������� "����" ��� �������, ���� ����� ��� - �������������:
        if Enabled and (TriggerType = TRIGGER_SOUND) and (Sound <> nil) then
          if (SoundPlayCount > 0) and (not Sound.IsPlaying()) then
          begin
            if Data.PlayCount > 0 then // ���� 0 - ������ ���� ����������
              SoundPlayCount := SoundPlayCount - 1;
            if Data.Local then
              Sound.PlayVolumeAt(X+(Width div 2), Y+(Height div 2), Data.Volume/255.0)
            else
              Sound.PlayPanVolume((Data.Pan-127.0)/128.0, Data.Volume/255.0);
            if Sound.IsPlaying() and g_Game_IsNet and g_Game_IsServer then
              MH_SEND_TriggerSound(gTriggers[a]);
          end;

      // ������� "�������" - ���� ���������:
        if (TriggerType = TRIGGER_TRAP) and (DoorTime = 0) and (Data.PanelID <> -1) then
        begin
          OpenDoor(Data.PanelID, Data.NoSound, Data.d2d_doors);
          DoorTime := -1;
        end;

      // ������� "����� 5 ���" - ���� ���������:
        if (TriggerType = TRIGGER_DOOR5) and (DoorTime = 0) and (Data.PanelID <> -1) then
        begin
        // ��� �������:
          if gWalls[Data.PanelID].Enabled then
            DoorTime := -1
          else // ���� ������� - ���������
            if CloseDoor(Data.PanelID, Data.NoSound, Data.d2d_doors) then
              DoorTime := -1;
        end;

      // ������� - ����������� ��� �������������, � ������ ��������, � ������ ������ ����� ���:
        if (TriggerType in [TRIGGER_PRESS, TRIGGER_ON, TRIGGER_OFF, TRIGGER_ONOFF]) and
           (PressTime = 0) and (PressCount >= Data.Count) then
        begin
        // ���������� �������� ���������:
          PressTime := -1;
        // ���������� ������� �������:
          if Data.Count > 0 then
            PressCount := PressCount - Data.Count
          else
            PressCount := 0;

        // ���������� ���������� �� ��������:
          for b := 0 to High(gTriggers) do
            if g_Collide(Data.tX, Data.tY, Data.tWidth, Data.tHeight, gTriggers[b].X, gTriggers[b].Y,
               gTriggers[b].Width, gTriggers[b].Height) and
               ((b <> a) or (Data.Wait > 0)) then
            begin // Can be self-activated, if there is Data.Wait
              if (not Data.ExtRandom) or gTriggers[b].Enabled then
              begin
                SetLength(Affected, Length(Affected) + 1);
                Affected[High(Affected)] := b;
              end;
            end;
        // �������� ���� �� ��������� ��� �����������, ���� ������� ������:
          if (TriggerType = TRIGGER_PRESS) and Data.ExtRandom then
          begin
            if (Length(Affected) > 0) then
            begin
              b := Affected[Random(Length(Affected))];
              gTriggers[b].ActivateUID := gTriggers[a].ActivateUID;
              ActivateTrigger(gTriggers[b], 0);
            end;
          end
          else // � ��������� ������ �������� ��� ������:
            for i := 0 to High(Affected) do
            begin
              b := Affected[i];
              case TriggerType of
                TRIGGER_PRESS:
                  begin
                    gTriggers[b].ActivateUID := gTriggers[a].ActivateUID;
                    ActivateTrigger(gTriggers[b], 0);
                  end;
                TRIGGER_ON:
                  begin
                    gTriggers[b].Enabled := True;
                  end;
                TRIGGER_OFF:
                  begin
                    gTriggers[b].Enabled := False;
                    gTriggers[b].TimeOut := 0;
                    if gTriggers[b].AutoSpawn then
                    begin
                      gTriggers[b].AutoSpawn := False;
                      gTriggers[b].SpawnCooldown := 0;
                    end;
                  end;
                TRIGGER_ONOFF:
                  begin
                    gTriggers[b].Enabled := not gTriggers[b].Enabled;
                    if not gTriggers[b].Enabled then
                    begin
                      gTriggers[b].TimeOut := 0;
                      if gTriggers[b].AutoSpawn then
                      begin
                        gTriggers[b].AutoSpawn := False;
                        gTriggers[b].SpawnCooldown := 0;
                      end;
                    end;
                  end;
              end;
            end;
          SetLength(Affected, 0);
        end;

      // ��������� ����� �� ����������� ��������� ���������:
        if TimeOut > 0 then
        begin
          TimeOut := TimeOut - 1;
          Continue; // ����� �� �������� 1 ������� ��������
        end;

      // ���� ���� ���� ���������, ���� ������� �������� - ��� ������
        if not Enabled then
          Continue;

      // "����� ������":
        if ByteBool(ActivateType and ACTIVATE_PLAYERCOLLIDE) and
           (TimeOut = 0) then
          if gPlayers <> nil then
            for b := 0 to High(gPlayers) do
              if gPlayers[b] <> nil then
                with gPlayers[b] do
                // ���, ���� ������ ����� � �� �����:
                  if Live and ((gTriggers[a].Keys and GetKeys) = gTriggers[a].Keys) and
                     Collide(X, Y, Width, Height) then
                  begin
                    gTriggers[a].ActivateUID := UID;

                    if (gTriggers[a].TriggerType in [TRIGGER_SOUND, TRIGGER_MUSIC]) and
                       PlayerCollide then
                      { Don't activate sound/music again if player is here }
                    else
                      ActivateTrigger(gTriggers[a], ACTIVATE_PLAYERCOLLIDE);
                  end;

        { TODO 5 : ��������� ��������� ��������� � ������� }

        if ByteBool(ActivateType and ACTIVATE_MONSTERCOLLIDE) and
           ByteBool(ActivateType and ACTIVATE_NOMONSTER) and
           (TimeOut = 0) and (Keys = 0) then
        begin
        // ���� "������ ������" � "�������� ���",
        // ��������� ������� �� ������ ����� � ������� ��� �����
          ActivateType := ActivateType and not (ACTIVATE_MONSTERCOLLIDE or ACTIVATE_NOMONSTER);
          gTriggers[a].ActivateUID := 0;
          ActivateTrigger(gTriggers[a], 0);
        end else
        begin
        // "������ ������":
          if ByteBool(ActivateType and ACTIVATE_MONSTERCOLLIDE) and
             (TimeOut = 0) and (Keys = 0) then // ���� �� ����� �����
            if gMonsters <> nil then
              for b := 0 to High(gMonsters) do
                if (gMonsters[b] <> nil) then
                  with gMonsters[b] do
                    if Collide(X, Y, Width, Height) then
                    begin
                      gTriggers[a].ActivateUID := UID;
                      ActivateTrigger(gTriggers[a], ACTIVATE_MONSTERCOLLIDE);
                    end;

        // "�������� ���":
          if ByteBool(ActivateType and ACTIVATE_NOMONSTER) and
             (TimeOut = 0) and (Keys = 0) then
            if not g_CollideMonster(X, Y, Width, Height) then
            begin
              gTriggers[a].ActivateUID := 0;
              ActivateTrigger(gTriggers[a], ACTIVATE_NOMONSTER);
            end;
        end;

        PlayerCollide := g_CollidePlayer(X, Y, Width, Height);
      end;
end;

procedure g_Triggers_Press(ID: DWORD; ActivateType: Byte);
begin
  gTriggers[ID].ActivateUID := 0;
  ActivateTrigger(gTriggers[ID], ActivateType);
end;

function g_Triggers_PressR(X, Y: Integer; Width, Height: Word; UID: Word;
                           ActivateType: Byte; IgnoreList: DWArray = nil): DWArray;
var
  a: Integer;
  k: Byte;
  p: TPlayer;
begin
  if gTriggers = nil then Exit;

  case g_GetUIDType(UID) of
    UID_GAME: k := 255;
    UID_PLAYER:
    begin
      p := g_Player_Get(UID);
      if p <> nil then
        k := p.GetKeys
      else
        k := 0;
    end;
    else k := 0;
  end;

  Result := nil;

  for a := 0 to High(gTriggers) do
    if (gTriggers[a].TriggerType <> TRIGGER_NONE) and
       (gTriggers[a].TimeOut = 0) and
       (not InDWArray(a, IgnoreList)) and
       ((gTriggers[a].Keys and k) = gTriggers[a].Keys) and
       ByteBool(gTriggers[a].ActivateType and ActivateType) then
      if g_Collide(X, Y, Width, Height,
         gTriggers[a].X, gTriggers[a].Y,
         gTriggers[a].Width, gTriggers[a].Height) then
      begin
        gTriggers[a].ActivateUID := UID;
        if ActivateTrigger(gTriggers[a], ActivateType) then
        begin
          SetLength(Result, Length(Result)+1);
          Result[High(Result)] := a;
        end;
      end;
end;

procedure g_Triggers_PressL(X1, Y1, X2, Y2: Integer; UID: DWORD; ActivateType: Byte);
var
  a: Integer;
  k: Byte;
  p: TPlayer;
begin
  if gTriggers = nil then Exit;

  case g_GetUIDType(UID) of
    UID_GAME: k := 255;
    UID_PLAYER:
    begin
      p := g_Player_Get(UID);
      if p <> nil then
        k := p.GetKeys
      else
        k := 0;
    end;
    else k := 0;
  end;

  for a := 0 to High(gTriggers) do
    if (gTriggers[a].TriggerType <> TRIGGER_NONE) and
       (gTriggers[a].TimeOut = 0) and
       ((gTriggers[a].Keys and k) = gTriggers[a].Keys) and
       ByteBool(gTriggers[a].ActivateType and ActivateType) then
      if g_CollideLine(x1, y1, x2, y2, gTriggers[a].X, gTriggers[a].Y,
         gTriggers[a].Width, gTriggers[a].Height) then
      begin
        gTriggers[a].ActivateUID := UID;
        ActivateTrigger(gTriggers[a], ActivateType);
      end;
end;

procedure g_Triggers_PressC(CX, CY: Integer; Radius: Word; UID: Word; ActivateType: Byte);
var
  a: Integer;
  k: Byte;
  rsq: Word;
  p: TPlayer;
begin
  if gTriggers = nil then
    Exit;

  case g_GetUIDType(UID) of
    UID_GAME: k := 255;
    UID_PLAYER:
    begin
     p := g_Player_Get(UID);
     if p <> nil then
      k := p.GetKeys
     else
      k := 0;
    end;
    else k := 0;
  end;

  rsq := Radius * Radius;

  for a := 0 to High(gTriggers) do
    if (gTriggers[a].TriggerType <> TRIGGER_NONE) and
       (gTriggers[a].TimeOut = 0) and
       ((gTriggers[a].Keys and k) = gTriggers[a].Keys) and
       ByteBool(gTriggers[a].ActivateType and ActivateType) then
      with gTriggers[a] do
        if g_Collide(CX-Radius, CY-Radius, 2*Radius, 2*Radius,
                     X, Y, Width, Height) then
          if ((Sqr(CX-X)+Sqr(CY-Y)) < rsq) or // ����� ����� ������ � �������� ������ ����
             ((Sqr(CX-X-Width)+Sqr(CY-Y)) < rsq) or // ����� ����� ������ � �������� ������� ����
             ((Sqr(CX-X-Width)+Sqr(CY-Y-Height)) < rsq) or // ����� ����� ������ � ������� ������� ����
             ((Sqr(CX-X)+Sqr(CY-Y-Height)) < rsq) or // ����� ����� ������ � ������� ������ ����
             ( (CX > (X-Radius)) and (CX < (X+Width+Radius)) and
               (CY > Y) and (CY < (Y+Height)) ) or // ����� ����� �������� �� ������������ ������ ��������������
             ( (CY > (Y-Radius)) and (CY < (Y+Height+Radius)) and
               (CX > X) and (CX < (X+Width)) ) then // ����� ����� �������� �� �������������� ������ ��������������
          begin
            ActivateUID := UID;
            ActivateTrigger(gTriggers[a], ActivateType);
          end;
end;

procedure g_Triggers_OpenAll();
var
  a: Integer;
  b: Boolean;
begin
  if gTriggers = nil then Exit;

  b := False;
  for a := 0 to High(gTriggers) do
    with gTriggers[a] do
      if (TriggerType = TRIGGER_OPENDOOR) or
         (TriggerType = TRIGGER_DOOR5) or
         (TriggerType = TRIGGER_DOOR) then
      begin
        OpenDoor(Data.PanelID, True, Data.d2d_doors);
        if TriggerType = TRIGGER_DOOR5 then DoorTime := 180;
        b := True;
      end;

  if b then g_Sound_PlayEx('SOUND_GAME_DOOROPEN');
end;

procedure g_Triggers_DecreaseSpawner(ID: DWORD);
begin
  if (gTriggers <> nil) then
    if gTriggers[ID].SpawnedCount > 0 then
      Dec(gTriggers[ID].SpawnedCount);
end;

procedure g_Triggers_Free();
var
  a: Integer;
begin
  if gTriggers <> nil then
    for a := 0 to High(gTriggers) do
    begin
      if gTriggers[a].TriggerType = TRIGGER_SOUND then
      begin
        if g_Sound_Exists(gTriggers[a].Data.SoundName) then
          g_Sound_Delete(gTriggers[a].Data.SoundName);

        gTriggers[a].Sound.Free();
      end;
      if gTriggers[a].Activators <> nil then
        SetLength(gTriggers[a].Activators, 0);
    end;

  gTriggers := nil;
  gSecretsCount := 0;
  SetLength(gMonstersSpawned, 0);
end;

procedure g_Triggers_SaveState(var Mem: TBinMemoryWriter);
var
  count, act_count, i, j: Integer;
  dw: DWORD;
  sg: Single;
  b: Boolean;
  p: Pointer;
begin
// ������� ���������� ������������ ���������:
  count := 0;
  if gTriggers <> nil then
    for i := 0 to High(gTriggers) do
      count := count + 1;

  Mem := TBinMemoryWriter.Create((count+1) * 200);

// ���������� ���������:
  Mem.WriteInt(count);

  if count = 0 then
    Exit;

  for i := 0 to High(gTriggers) do
  begin
  // ��������� ��������:
    dw := TRIGGER_SIGNATURE; // 'TRGR'
    Mem.WriteDWORD(dw);
  // ��� ��������:
    Mem.WriteByte(gTriggers[i].TriggerType);
  // ����������� ������ ��������:
    p := @gTriggers[i].Data;
    Mem.WriteMemory(p, SizeOf(TTriggerData));
  // ���������� ������ �������� ����:
    Mem.WriteInt(gTriggers[i].X);
    Mem.WriteInt(gTriggers[i].Y);
  // �������:
    Mem.WriteWord(gTriggers[i].Width);
    Mem.WriteWord(gTriggers[i].Height);
  // ������� �� �������:
    Mem.WriteBoolean(gTriggers[i].Enabled);
  // ��� ��������� ��������:
    Mem.WriteByte(gTriggers[i].ActivateType);
  // �����, ����������� ��� ���������:
    Mem.WriteByte(gTriggers[i].Keys);
  // ID ������, �������� ������� ���������:
    Mem.WriteInt(gTriggers[i].TexturePanel);
  // ��� ���� ������:
    Mem.WriteWord(gTriggers[i].TexturePanelType);
  // ����� �� ����������� ���������:
    Mem.WriteWord(gTriggers[i].TimeOut);
  // UID ����, ��� ����������� ���� �������:
    Mem.WriteWord(gTriggers[i].ActivateUID);
  // ������ UID-�� ��������, ������� ���������� ��� ������������:
    act_count := Length(gTriggers[i].Activators);
    Mem.WriteInt(act_count);
    for j := 0 to act_count-1 do
    begin
      // UID �������
      Mem.WriteWord(gTriggers[i].Activators[j].UID);
      // ����� ��������
      Mem.WriteWord(gTriggers[i].Activators[j].TimeOut);
    end;
  // ����� �� ����� � ������� ��������:
    Mem.WriteBoolean(gTriggers[i].PlayerCollide);
  // ����� �� �������� �����:
    Mem.WriteInt(gTriggers[i].DoorTime);
  // �������� ���������:
    Mem.WriteInt(gTriggers[i].PressTime);
  // ������� �������:
    Mem.WriteInt(gTriggers[i].PressCount);
  // ������� �������:
    Mem.WriteBoolean(gTriggers[i].AutoSpawn);
  // �������� ��������:
    Mem.WriteInt(gTriggers[i].SpawnCooldown);
  // ������� �������� ��������:
    Mem.WriteInt(gTriggers[i].SpawnedCount);
  // ������� ��� �������� ����:
    Mem.WriteInt(gTriggers[i].SoundPlayCount);
  // ������������� �� ����?
    if gTriggers[i].Sound <> nil then
      b := gTriggers[i].Sound.IsPlaying()
    else
      b := False;
    Mem.WriteBoolean(b);
    if b then
    begin
    // ������� ������������ �����:
      dw := gTriggers[i].Sound.GetPosition();
      Mem.WriteDWORD(dw);
    // ��������� �����:
      sg := gTriggers[i].Sound.GetVolume();
      sg := sg / (gSoundLevel/255.0);
      Mem.WriteSingle(sg);
    // ������ �������� �����:
      sg := gTriggers[i].Sound.GetPan();
      Mem.WriteSingle(sg);
    end;
  end;
end;

procedure g_Triggers_LoadState(var Mem: TBinMemoryReader);
var
  count, act_count, i, j, a: Integer;
  dw: DWORD;
  vol, pan: Single;
  b: Boolean;
  p: Pointer;
  Trig: TTrigger;
begin
  if Mem = nil then
    Exit;

  g_Triggers_Free();

// ���������� ���������:
  Mem.ReadInt(count);

  if count = 0 then
    Exit;

  for a := 0 to count-1 do
  begin
  // ��������� ��������:
    Mem.ReadDWORD(dw);
    if dw <> TRIGGER_SIGNATURE then // 'TRGR'
    begin
      raise EBinSizeError.Create('g_Triggers_LoadState: Wrong Trigger Signature');
    end;
  // ��� ��������:
    Mem.ReadByte(Trig.TriggerType);
  // ����������� ������ ��������:
    Mem.ReadMemory(p, dw);
    if dw <> SizeOf(TTriggerData) then
    begin
      raise EBinSizeError.Create('g_Triggers_LoadState: Wrong TriggerData Size');
    end;
    Trig.Data := TTriggerData(p^);
  // ������� �������:
    i := g_Triggers_Create(Trig);
  // ���������� ������ �������� ����:
    Mem.ReadInt(gTriggers[i].X);
    Mem.ReadInt(gTriggers[i].Y);
  // �������:
    Mem.ReadWord(gTriggers[i].Width);
    Mem.ReadWord(gTriggers[i].Height);
  // ������� �� �������:
    Mem.ReadBoolean(gTriggers[i].Enabled);
  // ��� ��������� ��������:
    Mem.ReadByte(gTriggers[i].ActivateType);
  // �����, ����������� ��� ���������:
    Mem.ReadByte(gTriggers[i].Keys);
  // ID ������, �������� ������� ���������:
    Mem.ReadInt(gTriggers[i].TexturePanel);
  // ��� ���� ������:
    Mem.ReadWord(gTriggers[i].TexturePanelType);
  // ����� �� ����������� ���������:
    Mem.ReadWord(gTriggers[i].TimeOut);
  // UID ����, ��� ����������� ���� �������:
    Mem.ReadWord(gTriggers[i].ActivateUID);
  // ������ UID-�� ��������, ������� ���������� ��� ������������:
    Mem.ReadInt(act_count);
    if act_count > 0 then
    begin
      SetLength(gTriggers[i].Activators, act_count);
      for j := 0 to act_count-1 do
      begin
        // UID �������
        Mem.ReadWord(gTriggers[i].Activators[j].UID);
        // ����� ��������
        Mem.ReadWord(gTriggers[i].Activators[j].TimeOut);
      end;
    end;
  // ����� �� ����� � ������� ��������:
    Mem.ReadBoolean(gTriggers[i].PlayerCollide);
  // ����� �� �������� �����:
    Mem.ReadInt(gTriggers[i].DoorTime);
  // �������� ���������:
    Mem.ReadInt(gTriggers[i].PressTime);
  // ������� �������:
    Mem.ReadInt(gTriggers[i].PressCount);
  // ������� �������:
    Mem.ReadBoolean(gTriggers[i].AutoSpawn);
  // �������� ��������:
    Mem.ReadInt(gTriggers[i].SpawnCooldown);
  // ������� �������� ��������:
    Mem.ReadInt(gTriggers[i].SpawnedCount);
  // ������� ��� �������� ����:
    Mem.ReadInt(gTriggers[i].SoundPlayCount);
  // ������������� �� ����?
    Mem.ReadBoolean(b);
    if b then
    begin
    // ������� ������������ �����:
      Mem.ReadDWORD(dw);
    // ��������� �����:
      Mem.ReadSingle(vol);
    // ������ �������� �����:
      Mem.ReadSingle(pan);
    // ��������� ����, ���� ����:
      if gTriggers[i].Sound <> nil then
      begin
        gTriggers[i].Sound.PlayPanVolume(pan, vol);
        gTriggers[i].Sound.Pause(True);
        gTriggers[i].Sound.SetPosition(dw);
      end
    end;
  end;
end;

end.
