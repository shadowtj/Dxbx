(*
    This file is part of Dxbx - a XBox emulator written in Delphi (ported over from cxbx)
    Copyright (C) 2007 Shadow_tj and other members of the development team.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)

unit uPushBuffer;

{$INCLUDE Dxbx.inc}

{.$define _DEBUG_TRACK_PB}

interface

uses
  // Delphi
  Windows
  , SysUtils
  , Classes
  // Jedi Win32API
  , JwaWinType
  // DirectX
{$IFDEF DXBX_USE_D3D9}
  , Direct3D9
{$ELSE}
  , Direct3D8
{$ENDIF}
  // Dxbx
  , uTypes
  , uDxbxUtils // iif
  , uEmuAlloc
  , uResourceTracker
  , uEmuD3D8Types
  , uEmuD3D8Utils
  , uVertexBuffer
  , uEmu
  , uEmuXG;

// From PushBuffer.h :

procedure XTL_EmuExecutePushBuffer
(
  pPushBuffer: PX_D3DPushBuffer;
  pFixup: PX_D3DFixup
); {NOPATCH}

procedure XTL_EmuApplyPushBufferFixup
(
  pdwPushData: PDWORD;
  pdwFixupData: PDWORD
); {NOPATCH}

procedure XTL_EmuExecutePushBufferRaw
(
  pdwPushData: PDWORD
); {NOPATCH}

// primary push buffer
var g_dwPrimaryPBCount: uint32 = 0;
var g_pPrimaryPB: PDWORD = nil; // Dxbx note : Cxbx uses Puint32 for this

// push buffer debugging
var XTL_g_bStepPush: _bool = false;
var XTL_g_bSkipPush: _bool = false;
var XTL_g_bBrkPush: _bool = false;

var g_bPBSkipPusher: _bool = false;

{$IFDEF _DEBUG_TRACK_PB}
procedure DbgDumpMesh(pIndexData: PWORD; dwCount: DWORD); {NOPATCH}
{$ENDIF}

implementation

uses
  // Dxbx
    uDxbxKrnlUtils
  , uLog
  , uConvert
  , uEmuD3D8 // DxbxPresent
  , uState
  , uVertexShader;

const NV2A_METHOD_MASK = $3FFFF; // 18 bits
const NV2A_COUNT_SHIFT = 18;
const NV2A_COUNT_MASK = $FFF; // 12 bits
const NV2A_NOINCREMENT_FLAG = $40000000;
// Dxbx note : What does the last bit (mask $80000000) mean?

const NV2A_MAX_COUNT = 2047;

const NV2A_NO_OPERATION                = $00000100; // Parameter must be zero
const NV2A_SET_TRANSFORM_CONSTANT      = $00000b80; // Can't use NOINCREMENT_FLAG, maximum of 32 writes
const NV2A_SET_BEGIN_END               = $000017fc; // Parameter is D3DPRIMITIVETYPE or 0 to end
const NV2A_InlineIndexArray            = $00001800;
const NV2A_FixLoop                     = $00001808;
const NV2A_DRAW_ARRAYS                 = $00001810;
const NV2A_INLINE_ARRAY                = $00001818; // Use NOINCREMENT_FLAG
const NV2A_SET_TRANSFORM_CONSTANT_LOAD = $00001ea4; // Add 96 to constant index parameter

const lfUnit = lfCxbx or lfPushBuffer;

procedure D3DPUSH_DECODE(const dwPushData: DWORD; out dwCount, dwMethod: DWORD; out bInc: BOOL_);
begin
  dwCount  := (dwPushData shr NV2A_COUNT_SHIFT) and NV2A_COUNT_MASK;
  dwMethod := (dwPushData and NV2A_METHOD_MASK);
  bInc     := (dwPushData and NV2A_NOINCREMENT_FLAG) > 0;
end;

// From PushBuffer.cpp :

procedure XTL_EmuExecutePushBuffer
(
    pPushBuffer: PX_D3DPushBuffer;
    pFixup: PX_D3DFixup
); {NOPATCH}
// Branch:shogun  Revision:0.8.1-Pre2  Translator:PatrickvL  Done:100
begin
  if (pFixup <> NULL) then
  begin
    XTL_EmuApplyPushBufferFixup(PDWORD(pPushBuffer.Data), PDWORD(pFixup.Data + pFixup.Run));
    // TODO : Should we change this in a while Assigned(pFixup := pFixup.Next) ?
  end;

  XTL_EmuExecutePushBufferRaw(PDWORD(pPushBuffer.Data));
end;


procedure XTL_EmuApplyPushBufferFixup
(
  pdwPushData: PDWORD;
  pdwFixupData: PDWORD
); {NOPATCH}
// Branch:Dxbx  Translator:PatrickvL  Done:100
var
  SizeInBytes: UInt;
  OffsetInBytes: UInt;
begin
  while True do
  begin
    SizeInBytes := pdwFixupData^;
    if SizeInBytes = $FFFFFFFF then
      Exit;

    Inc(pdwFixupData);
    OffsetInBytes := pdwFixupData^;
    Inc(pdwFixupData);

    memcpy({dest=}Pointer(UIntPtr(pdwPushData) + OffsetInBytes), {src=}pdwFixupData, SizeInBytes);
    Inc(UIntPtr(pdwFixupData), SizeInBytes);
  end;

(*
  When IDirect3DDevice8::RunPushBuffer is called with a fix-up object specified,
  it will parse the fix-up data pointed to by Data and with a byte offset of Run.

  The fix-up data is encoded as follows. The first DWORD is the size, in bytes,
  of the push-buffer fix-up to be modified. The second DWORD is the offset, in bytes,
  from the start of the push-buffer where the fix-up is to be modified.

  The subsequent DWORDS are the data to be copied. This encoding repeats for every fix-up to be done,
  until it terminates with a size value of 0xffffffff.

  The offsets must be in an increasing order.
*)
end;

{static} var pIndexBuffer: XTL_LPDIRECT3DINDEXBUFFER8 = nil; // = XTL_PIDirect3DIndexBuffer8
//{static} var pVertexBuffer: XTL_LPDIRECT3DVERTEXBUFFER8 = nil; // = XTL_PIDirect3DVertexBuffer8
{static} var maxIBSize: uint = 0;
procedure XTL_EmuExecutePushBufferRaw
(
    pdwPushData: PDWord
); {NOPATCH}
// Branch:shogun  Revision:0.8.1-Pre2  Translator:PatrickvL  Done:100
var
  pIndexData: PVOID;
  pVertexData: PVOID;
  dwVertexShader: DWord;
  dwStride: DWord;
  pIBMem: array [0..4-1] of WORD;
  PCPrimitiveType: D3DPRIMITIVETYPE;
  XBPrimitiveType: X_D3DPRIMITIVETYPE;
  dwCount: DWord;
  dwMethod: DWord;
  bInc: BOOL_;
  hRet: HRESULT;
  pData: PWORDArray;
  VertexCount: UINT;
  PrimitiveCount: UINT;
  VPDesc: VertexPatchDesc;
  VertPatch: VertexPatcher;
  pwVal: PWORDs;

{$ifdef _DEBUG_TRACK_PB}
  pdwOrigPushData: PDWORD;
  bShowPB: _bool;
  s: uint;
  pActiveVB: XTL_PIDirect3DVertexBuffer8;
  VBDesc: D3DVERTEXBUFFER_DESC;
  pVBData: PBYTE;
{$IFDEF DXBX_USE_D3D9}
  uiOffsetInBytes: UINT;
{$ENDIF}
  uiStride: UINT;
{$endif}

  procedure _AssureIndexBuffer;
  begin
    // TODO -oCXBX: depreciate maxIBSize after N milliseconds..then N milliseconds later drop down to new highest
    if (maxIBSize < (dwCount*SizeOf(WORD))) then
    begin
      maxIBSize := dwCount*SizeOf(WORD);

      if (pIndexBuffer <> nil) then
      begin
        IDirect3DIndexBuffer(pIndexBuffer)._Release();
        pIndexBuffer := nil; // Dxbx addition - nil out after decreasing reference count
      end;

      hRet := IDirect3DDevice_CreateIndexBuffer(g_pD3DDevice, maxIBSize, {Usage=}0, D3DFMT_INDEX16, D3DPOOL_MANAGED, PIDirect3DIndexBuffer(@pIndexBuffer));
    end
    else
    begin
      hRet := D3D_OK;
    end;

    if (FAILED(hRet)) then
      DxbxKrnlCleanup('Unable to create index buffer for PushBuffer emulation (0x%.04X, dwCount : %d)', [dwMethod, dwCount]);
  end;

  procedure _RenderIndexedVertices;
  begin
    PrimitiveCount := EmuD3DVertex2PrimitiveCount(XBPrimitiveType, dwCount);
    VPDesc.VertexPatchDesc(); // Dxbx addition : explicit initializer

    VPDesc.dwVertexCount := dwCount;
    VPDesc.PrimitiveType := XBPrimitiveType;
    VPDesc.dwPrimitiveCount := PrimitiveCount;
    VPDesc.dwOffset := 0;
    VPDesc.pVertexStreamZeroData := nil;
    VPDesc.uiVertexStreamZeroStride := 0;
    // TODO -oCXBX: Set the current shader and let the patcher handle it..
    VPDesc.hVertexShader := g_CurrentVertexShader;

    VertPatch.VertexPatcher(); // Dxbx addition : explicit initializer

    {Dxbx unused bPatched :=} VertPatch.Apply(@VPDesc, NULL);

    g_pD3DDevice.SetIndices(IDirect3DIndexBuffer(pIndexBuffer){$IFNDEF DXBX_USE_D3D9}, 0{$ENDIF});

{$ifdef _DEBUG_TRACK_PB}
    if (not g_PBTrackDisable.exists(pdwOrigPushData)) then
{$endif}
    begin
      if (not g_bPBSkipPusher) then
      begin
        if (IsValidCurrentShader()) then
        begin
          g_pD3DDevice.DrawIndexedPrimitive
          (
            PCPrimitiveType,
{$IFDEF DXBX_USE_D3D9}
            {BaseVertexIndex=}0,
{$ENDIF}
            {MinVertexIndex=}0,
            VPDesc.dwVertexCount,
            0,
            PrimitiveCount
            // Dxbx : Why not this : EmuXB2PC_D3DPrimitiveType(VPDesc.PrimitiveType), 0, VPDesc.dwVertexCount, 0, VPDesc.dwPrimitiveCount
          );
        end;
      end;
    end;

    VertPatch.Restore();

    g_pD3DDevice.SetIndices(nil{$IFNDEF DXBX_USE_D3D9}, 0{$ENDIF});
  end;

begin
  if XTL_g_bSkipPush then
    Exit;

{$ifdef _DEBUG_TRACK_PB}
  pdwOrigPushData := pdwPushData;
{$endif}

  //pIndexData := nil;
  //pVertexData := nil;

  dwVertexShader := DWORD(-1);
  //dwStride := DWORD(-1);

  // cache of last 4 indices
  pIBMem[0] := $FFFF; pIBMem[1] := $FFFF; pIBMem[2] := $FFFF; pIBMem[3] := $FFFF;

  PCPrimitiveType := D3DPRIMITIVETYPE(-1);
  XBPrimitiveType := X_D3DPT_INVALID;

  DxbxUpdateNativeD3DResources();

{$ifdef _DEBUG_TRACK_PB}
  bShowPB := false;

  g_PBTrackTotal.insert(pdwPushData);

  if (not g_PBTrackShowOnce.exists(pdwPushData)) then
  begin
    g_PBTrackShowOnce.insert(pdwPushData);

    if MayLog(lfUnit) then
    begin
      DbgPrintf('');
      DbgPrintf('');
      DbgPrintf('  PushBuffer@0x%.08X...', [pdwPushData]);
      DbgPrintf('');
    end;

    bShowPB := true;
  end;
{$endif}

  (* Dxbx note : Do not initialize these 'static' var's :
  pIndexBuffer := nil;
  pVertexBuffer := nil;

  maxIBSize := 0;
  *)

  while (true) do
  begin
    // Decode push buffer contents (inverse of D3DPUSH_ENCODE) :
    D3DPUSH_DECODE(pdwPushData^, {out}dwCount, {out}dwMethod, {out}bInc);
    Inc(pdwPushData);

    if MayLog(lfUnit) then
      DbgPrintf('  Method: 0x%.08X   Count: 0x%.08X   PrimType: 0x%.03x %s', [
        dwMethod, dwCount, Ord(XBPrimitiveType), X_D3DPRIMITIVETYPE2String(XBPrimitiveType)]);

    // Interpret GPU Instruction :
    case dwMethod of

      NV2A_NO_OPERATION:
        Inc(pdwPushData, dwCount); // TODO -oDxbx: Is this correct, or should we skip only one DWORD?

      NV2A_SET_BEGIN_END:
      begin
        XBPrimitiveType := X_D3DPRIMITIVETYPE(pdwPushData^);
        if (XBPrimitiveType = X_D3DPT_NONE) then
        begin
{$ifdef _DEBUG_TRACK_PB}
          if (bShowPB) then
            DbgPrintf('  NV2A_SetBeginEnd(DONE)');
{$endif}
//          break;  // done?
        end
        else
        begin
{$IFDEF _DEBUG_TRACK_PB}
          if (bShowPB) then
            DbgPrintf('  NV2A_SetBeginEnd(PrimitiveType = %d)', [pdwPushData^]);
{$endif}

          PCPrimitiveType := EmuXB2PC_D3DPrimitiveType(XBPrimitiveType);
        end;

        Assert(dwCount = 1); // TODO -oDxbx: What if this isn't true?
        Inc(pdwPushData, dwCount);
      end;

      NV2A_INLINE_ARRAY:
      begin
        pVertexData := pdwPushData;
        Inc(pdwPushData, dwCount);

        // retrieve vertex shader
{$IFDEF DXBX_USE_D3D9}
        // For Direct3D9, try to retrieve the vertex shader interface :
        dwVertexShader := 0;
        g_pD3DDevice.GetVertexShader({out}PIDirect3DVertexShader9(@dwVertexShader));
        // If that didn't work, get the active FVF :
        if dwVertexShader = 0 then
          g_pD3DDevice.GetFVF({out}dwVertexShader);
{$ELSE}
        g_pD3DDevice.GetVertexShader({out}dwVertexShader);
{$ENDIF}

        if (dwVertexShader > $FFFF) then
        begin
          DxbxKrnlCleanup('Non-FVF Vertex Shaders not yet supported for PushBuffer emulation!');
          dwVertexShader := 0;
        end
        else if (dwVertexShader = 0) then
        begin
          EmuWarning('FVF Vertex Shader is null');
          dwVertexShader := DWORD(-1);
        end;

        //
        // calculate stride
        //

        dwStride := 0;
        if (VshHandleIsFVF(dwVertexShader)) then
        begin
          dwStride := DxbxFVFToVertexSizeInBytes(dwVertexShader, {IncludeTextures=}True);
        end;

        (* MARKED OUT BY CXBX
        // create cached vertex buffer only once, with maxed out size
        if (pVertexBuffer = nil) then
        begin
          hRet := g_pD3DDevice.CreateVertexBuffer(2047*SizeOf(DWORD), D3DUSAGE_WRITEONLY, dwVertexShader, D3DPOOL_MANAGED, @pVertexBuffer);

          if (FAILED(hRet)) then
            DxbxKrnlCleanup('Unable to create vertex buffer cache for PushBuffer emulation ($1818, dwCount : %d)', [dwCount]);

        end;

        // copy vertex data
        begin
          pData: Puint8 := nil;

          hRet := pVertexBuffer.Lock(0, dwCount*4, @pData, 0);

          if (FAILED(hRet)) then
            DxbxKrnlCleanup('Unable to lock vertex buffer cache for PushBuffer emulation ($1818, dwCount : %d)', [dwCount]);

          memcpy({dest}pData, {src=}pVertexData, dwCount*4);

          pVertexBuffer.Unlock();
        end;
        *)

{$ifdef _DEBUG_TRACK_PB}
        if (bShowPB) then
        begin
          DbgPrintf('  NV2A_InlineVertexArray(...)');
          DbgPrintf('  dwCount : %d', [dwCount]);
          DbgPrintf('  dwVertexShader : 0x%08X', [dwVertexShader]);
        end;
{$endif}

        // render vertices
        if (dwVertexShader <> DWord(-1)) then
        begin
          VertexCount := (dwCount*sizeof(DWORD)) div dwStride;
          PrimitiveCount := EmuD3DVertex2PrimitiveCount(XBPrimitiveType, VertexCount);

          VPDesc.VertexPatchDesc(); // Dxbx addition : explicit initializer

          VPDesc.dwVertexCount := VertexCount;
          VPDesc.PrimitiveType := XBPrimitiveType;
          VPDesc.dwPrimitiveCount := PrimitiveCount;
          VPDesc.dwOffset := 0;
          VPDesc.pVertexStreamZeroData := pVertexData;
          VPDesc.uiVertexStreamZeroStride := dwStride;
          VPDesc.hVertexShader := dwVertexShader;

          VertPatch.VertexPatcher(); // Dxbx addition : explicit initializer

          {Dxbx unused bPatched :=} VertPatch.Apply(@VPDesc, NULL);

          g_pD3DDevice.DrawPrimitiveUP
          (
              PCPrimitiveType, // Dxbx : Why not this : EmuXB2PC_D3DPrimitiveType(VPDesc.PrimitiveType),
              VPDesc.dwPrimitiveCount,
              VPDesc.pVertexStreamZeroData,
              VPDesc.uiVertexStreamZeroStride
          );

          VertPatch.Restore();
        end;
      end;

      NV2A_FixLoop:
      begin
        pwVal := PWORDs(pdwPushData);
        Inc(pdwPushData, dwCount);

{$ifdef _DEBUG_TRACK_PB}
        if (bShowPB) then
        begin
          DbgPrintf('  NV2A_FixLoop(%d)', [dwCount]);
          DbgPrintf('');
          DbgPrintf('  Index Array Data...');

          if dwCount > 0 then // Dxbx addition, to prevent underflow
          for s := 0 to dwCount - 1 do
          begin
            if ((s mod 8) = 0) then printf(#13#10'  ');

            printf('  %.04X', [pwVal[s]]);
          end;

          printf(#13#10);
          DbgPrintf('');
        end;
{$endif}

        // See if we kept 2 previous indices :
        if (pIBMem[0] <> $FFFF) then
          Inc(dwCount, 2);

        // perform rendering
        if (dwCount > 2) then
        begin
          _AssureIndexBuffer;

          // copy index data
          begin
            pData := nil;

            IDirect3DIndexBuffer(pIndexBuffer).Lock(0, dwCount*SizeOf(WORD), {out}TLockData(pData), 0);

            if (pIBMem[0] <> $FFFF) then
            begin
              // If present, first insert previous two indices :
              memcpy({dest}pData, {src=}@pIBMem[0], 2*SizeOf(WORD));
              Inc(UIntPtr(pData), 2*SizeOf(WORD));
            end;

            memcpy({dest}pData, {src=}pwVal, dwCount*SizeOf(WORD));

            IDirect3DIndexBuffer(pIndexBuffer).Unlock();
          end;

          _RenderIndexedVertices;
        end;

      end;

      NV2A_InlineIndexArray:
      begin
        pIndexData := pdwPushData;
        Inc(pdwPushData, dwCount);
//Debugging aid for Turok menu - this removes most of the black popping triangles (which should become Dinosaurs) :
//if dwCount > $80 then
//  Exit;

        if bInc then
          dwCount := dwCount * 2; // Convert DWORD count to WORD count

{$ifdef _DEBUG_TRACK_PB}
        if (bShowPB) then
        begin
          DbgPrintf('  NV2A_InlineIndexArray(0x%.08X, %d)...', [pIndexData, dwCount]);
          DbgPrintf('');
          DbgPrintf('  Index Array Data...');

          pwVal := PWORDs(pIndexData);

          if dwCount > 0 then // Dxbx addition, to prevent underflow
          for s := 0 to dwCount - 1 do
          begin
            if ((s mod 8) = 0) then printf(#13#10'  ');

            printf('  %.04X', [pwVal[s]]);
          end;

          printf(#13#10);

          pActiveVB := nil;

          pVBData := nil;

          // retrieve stream data
          g_pD3DDevice.GetStreamSource(
            0,
            @pActiveVB,
{$IFDEF DXBX_USE_D3D9}
            {out}uiOffsetInBytes,
{$ENDIF}
            {out}uiStride);

          // retrieve stream desc
          IDirect3DVertexBuffer(pActiveVB).GetDesc({out}VBDesc);

          // unlock just in case
          IDirect3DVertexBuffer(pActiveVB).Unlock();

          // grab ptr
          IDirect3DVertexBuffer(pActiveVB).Lock(0, 0, {out}TLockData(pVBData), D3DLOCK_READONLY);

          // print out stream data
          begin
            if MayLog(lfUnit) then
            begin
              DbgPrintf('');
              DbgPrintf('  Vertex Stream Data (0x%.08X)...', [pActiveVB]);
              DbgPrintf('');
              DbgPrintf('  Format : %d', [Ord(VBDesc.Format)]);
              DbgPrintf('  Size   : %d bytes', [VBDesc.Size]);
              DbgPrintf('  FVF    : 0x%.08X', [VBDesc.FVF]);
              DbgPrintf('');
            end;
          end;

          // release ptr
          IDirect3DVertexBuffer(pActiveVB).Unlock();

          DbgDumpMesh(PWORD(pIndexData), dwCount);
        end;
{$endif}

        // perform rendering
        begin
          _AssureIndexBuffer;

          // copy index data
          begin
            pData := nil;

            IDirect3DIndexBuffer(pIndexBuffer).Lock(0, dwCount*SizeOf(WORD), {out}TLockData(pData), 0);

            memcpy({Dest=}pData, {src=}pIndexData, dwCount*SizeOf(WORD));

            // remember last 2 indices (will be used in FixLoop) :
            if (dwCount >= 2) then
            begin
              pIBMem[0] := pData[dwCount - 2];
              pIBMem[1] := pData[dwCount - 1];
            end
            else
            begin
              pIBMem[0] := $FFFF;
            end;

            IDirect3DIndexBuffer(pIndexBuffer).Unlock();
          end;

          _RenderIndexedVertices;
        end;
      end;

      0:
        Exit;
    else
      EmuWarning('Unknown PushBuffer Operation (0x%.04X, %d)', [dwMethod, dwCount]);
      Inc(pdwPushData, dwCount);
    end; // case
  end; // while true

{$ifdef _DEBUG_TRACK_PB}
  if (bShowPB) then
  begin
    DbgPrintf('');
    DbgPrintf('DxbxDbg> ');
    fflush(stdout);
  end;
{$endif}

  if (XTL_g_bStepPush) then
  begin
    DxbxPresent(nil, nil, 0, nil);
    Sleep(500);
  end;
end;


{$IFDEF _DEBUG_TRACK_PB}

procedure DbgDumpMesh(pIndexData: PWORD; dwCount: DWORD); {NOPATCH}
// Branch:shogun  Revision:0.8.1-Pre2  Translator:PatrickvL  Done:100
var
  pActiveVB: XTL_PIDirect3DVertexBuffer8;
  VBDesc: D3DVERTEXBUFFER_DESC;
  pVBData: PBYTE;
{$IFDEF DXBX_USE_D3D9}
  uiOffsetInBytes: UINT;
{$ENDIF}
  uiStride: UINT;
  szFileName: array [0..128 - 1] of AnsiChar;
  pwVal: PWORD;
  maxIndex: uint32;
  pwChk: PWORD;
  chk: uint;
  x: DWORD;
  dbgVertices: PFILE;
  max: uint;
  v: uint;
  a: DWORD;
  b: DWORD;
  c: DWORD;
//  la, lb, lc: DWORD;
  i: uint;
begin
  if (not IsValidCurrentShader() or (dwCount = 0)) then
    Exit;

  pActiveVB := NULL;

  pVBData := nil;
  
  // retrieve stream data
  g_pD3DDevice.GetStreamSource(
    0,
    @pActiveVB,
{$IFDEF DXBX_USE_D3D9}
    {out}uiOffsetInBytes,
{$ENDIF}
    {out}uiStride);

  sprintf(@szFileName[0], AnsiString(DxbxDebugFolder +'\DxbxMesh-0x%.08X.x'), [UIntPtr(pIndexData)]);
  dbgVertices := fopen(szFileName, 'wt');

  // retrieve stream desc
  IDirect3DVertexBuffer(pActiveVB).GetDesc({out}VBDesc);

  // unlock just in case
  IDirect3DVertexBuffer(pActiveVB).Unlock();

  // grab ptr
  IDirect3DVertexBuffer(pActiveVB).Lock(0, 0, {out}TLockData(pVBData), D3DLOCK_READONLY);

  // print out stream data
  if Assigned(dbgVertices) then // Dxbx addition
  begin
    maxIndex := 0;

    pwChk := PWORD(pIndexData);

    if dwCount > 0 then // Dxbx addition, to prevent underflow
    for chk := 0 to dwCount - 1 do
    begin
      x := pwChk^; Inc(pwChk);

      if (maxIndex < x) then
        maxIndex := x;
    end;

    if (maxIndex > ((VBDesc.Size div uiStride) - 1)) then
      maxIndex := (VBDesc.Size div uiStride) - 1;

    fprintf(dbgVertices, 'xof 0303txt 0032'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, '//'#13#10);
    fprintf(dbgVertices, '//  Vertex Stream Data (0x%.08X)...'#13#10, [UIntPtr(pActiveVB)]);
    fprintf(dbgVertices, '//'#13#10);
    fprintf(dbgVertices, '//  Format : %d'#13#10, [Ord(VBDesc.Format)]);
    fprintf(dbgVertices, '//  Size   : %d bytes'#13#10, [VBDesc.Size]);
    fprintf(dbgVertices, '//  FVF    : 0x%.08X'#13#10, [VBDesc.FVF]);
    fprintf(dbgVertices, '//  iCount : %d'#13#10, [dwCount div 2]);
    fprintf(dbgVertices, '//'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, 'Frame SCENE_ROOT {'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, '  FrameTransformMatrix {'#13#10);
    fprintf(dbgVertices, '    1.000000,0.000000,0.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '    0.000000,1.000000,0.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '    0.000000,0.000000,1.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '    0.000000,0.000000,0.000000,1.000000;'#13#10);
    fprintf(dbgVertices, '  }'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, '  Frame Turok1 {'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, '    FrameTransformMatrix {'#13#10);
    fprintf(dbgVertices, '      1.000000,0.000000,0.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '      0.000000,1.000000,0.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '      0.000000,0.000000,1.000000,0.000000,'#13#10);
    fprintf(dbgVertices, '      0.000000,0.000000,0.000000,1.000000;'#13#10);
    fprintf(dbgVertices, '    }'#13#10);
    fprintf(dbgVertices, ''#13#10);
    fprintf(dbgVertices, '    Mesh {'#13#10);
    fprintf(dbgVertices, '      %d;'#13#10, [maxIndex + 1]);

    max := maxIndex + 1;
    for v := 0 to max -1 do
    begin
      fprintf(dbgVertices, '      %f;%f;%f;%s'#13#10, [
        PFLOAT(@pVBData[v * uiStride + 0])^,
        PFLOAT(@pVBData[v * uiStride + 4])^,
        PFLOAT(@pVBData[v * uiStride + 8])^,
        iif(v < (max - 1), ',', ';')]);
    end;

    fprintf(dbgVertices, '      %d;'#13#10, [dwCount - 2]);

    pwVal := PWORD(pIndexData);

    max := dwCount;

    a := pwVal^; Inc(pwVal);
    b := pwVal^; Inc(pwVal);
    c := pwVal^; Inc(pwVal);

//    la := a; lb := b; lc := c;

    if max > 0 then // Dxbx addition, to prevent underflow
    for i := 2 to max - 1 do
    begin
      fprintf(dbgVertices, '      3;%d,%d,%d;%s'#13#10,
        [a, b, c, iif(i < (max - 1), ',', ';')]);

      a := b;
      b := c;
      c := pwVal^; Inc(pwVal);

//      la := a;
//      lb := b;
//      lc := c;
    end;

    fprintf(dbgVertices, '    }'#13#10);
    fprintf(dbgVertices, '  }'#13#10);
    fprintf(dbgVertices, '}'#13#10);

    fclose(dbgVertices);
  end;

  // release ptr
  IDirect3DVertexBuffer(pActiveVB).Unlock();
end;
{$ENDIF}

end.
