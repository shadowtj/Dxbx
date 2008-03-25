{
   xISO
   Copyright 1984, 1986, 1989, 1992, 2000, 2001, 2002
   Free Software Foundation, Inc.

   This file is part of xISO, made it by Yursoft.com

   xISO is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   Bison is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with Bison; see the file COPYING.  If not, write to the Free
   Software Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
   02111-1307, USA.
}


unit uxiso;

interface

uses windows, classes, sysutils, dialogs, CDROM;

const
 XBOX_MEDIA = 'MICROSOFT*XBOX*MEDIA';
 CD_SECTOR: int64 = 32;
 IMG_SECTOR: int64 = 32;
 DVD_SECTOR: int64 = 198176;
 TAM_SECTOR = 2048;

 XF_SOLOLECTURA = $01;
 XF_OCULTO = $02;
 XF_SISTEMA = $04;
 XF_DIRECTORIO = $10;
 XF_FICHERO = $20;
 XF_NORMAL = $80; 
                  
type

{$A-}
TxVD = record
 IDIn: array[0..19] of char;
 DirRaiz: integer;
 TamRaiz: integer;
 FechaHora: FILETIME;
 SinUso: array[0..1991] of byte;
 IDOut: array[0..19] of char;
end;
{$A+}

pxFichero = ^TxFichero;
TxFichero = record
 pIzq: word;
 pDer: word;
 SectorIn: integer;
 Tamano: integer;
 Atributo: byte;
 LongNombre: byte;
 Nombre: array[0..255] of byte;
 DirPadre: integer;
 DirHijo: integer;
end;

TxTablaDirectorio = record

end;

TxISO = record
 Lista: TList;
 xVD: TxVD;
 numFicheros: integer;
 numCarpetas: integer;
 tamISO: int64;
end;

var
 xIISO: TxISO;
 CDDVD_VD: int64;

function AbrirXISO(imagen: string): boolean;
function LeerXDVD(HA,SCSI,LUN: byte; Unidad: TCDROM): boolean;
procedure ExtraerFichero(fichero: string; grabar: string; sector, tamano: int64);
procedure ExtraerFicheroXDVD(HA,SCSI,LUN: byte;Unidad: TCDROM;grabar: string; sector, tamano: int64);

implementation

{ SECCION DE LECTURA DESDE IMAGEN }

procedure ExtraerFichero(fichero: string; grabar: string; sector, tamano: int64);
var
   fxiso,fguardar: TFilestream;
   i,fin: int64;
   buffer: array[0..2047] of byte;
begin
     sector := sector+IMG_SECTOR-32;
     fxiso := TFilestream.Create(fichero, fmOpenRead or fmShareDenyNone);
     fguardar := TFilestream.Create(grabar, fmCreate or fmShareDenyNone);
     fxiso.Seek(sector*TAM_SECTOR, soBeginning);
     fin := ((Tamano div 2048)*2048)+Sector*TAM_SECTOR;

     while (fxiso.Position < fin) do
     begin
          fxiso.Read(buffer, sizeof(buffer));
          fguardar.Write(buffer, sizeof(buffer));
     end;

     if (tamano mod 2048) <> 0 then
     begin
          fxiso.Read(buffer,tamano mod 2048);
          fguardar.Write(buffer,tamano mod 2048);
     end;

     fguardar.Free;
     fxiso.Free;
end;

// FALTA POR HACER
// UNFINISHED
procedure ModificarEntrada(Sector: int64; TamSector: int64; var Numero: int64; var Entrada: TxFichero; Fichero: TFilestream);
var
   MemBuf: TMemoryStream;
   xFichero: TxFichero;
   pNombre: PChar;
   i: int64;
   Offset: int64;
   Total,j: integer;
begin
     if (Sector = $FFFFFFFFFFFFFFFF) then Exit
     else
     begin
          i := Numero;
          offset := Sector*TAM_SECTOR;
          offset := Fichero.Seek(offset, soBeginning);

          MemBuf := TMemoryStream.Create();
          try
             MemBuf.CopyFrom(Fichero, TamSector);
          except end;
          MemBuf.Seek(0, soBeginning);

          Total := TamSector div 2048;
          if (TamSector mod 2048) <> 0 then Total := Total+1;

          for j := 0 to Total-1 do
          begin
           MemBuf.Seek(j*2048,soBeginning); 
           while not (MemBuf.Position >= (j+1)*2048) do
           begin
                Fillchar(xFichero, SizeOf(xFichero), $00);

                xFichero.pIzq := $FFFF;                
                MemBuf.Read(xFichero,14);
                MemBuf.Read(xFichero.Nombre,xFichero.LongNombre);

                if (xFichero.pIzq = $FFFF) then Break;

                if (Trim(PCHAR(@xFichero.Nombre)) = Trim(PCHAR(@Entrada.Nombre))) and
                   (xFichero.Tamano = Entrada.Tamano) and
                   (xFichero.SectorIn = Entrada.SectorIn) and
                   (xFichero.pDer = Entrada.pDer) then
                begin
                    // todo
                end;

                if ((xFichero.Atributo and XF_DIRECTORIO) = XF_DIRECTORIO) then
                begin
                   Numero := Numero+1;
                   if (xFichero.Tamano <> 0) and (xFichero.SectorIn <> 0) then
                     ModificarEntrada(xFichero.SectorIn+IMG_SECTOR-32, xFichero.Tamano, Numero, Entrada, Fichero);
                end;

                if ((MemBuf.Position mod 4) <> 0) then
                  MemBuf.Seek(MemBuf.Position+4-(MemBuf.Position mod 4),soBeginning);
           end;
          end;
     end;
     MemBuf.Free;
end;

procedure LeerTablaFicheros(Sector: int64; TamSector: int64; var Numero: int64; Fichero: TFilestream);
var
   MemBuf: TMemoryStream;
   xFichero: pxFichero;
   pNombre: PChar;
   i: int64;
   Offset: int64;
   Total,j: integer;
begin
     if (Sector = $FFFFFFFFFFFFFFFF) then Exit
     else
     begin
          i := Numero;
          offset := Sector*TAM_SECTOR;
          offset := Fichero.Seek(offset, soBeginning);

          MemBuf := TMemoryStream.Create();
          try
             MemBuf.CopyFrom(Fichero, TamSector);
          except end;
          MemBuf.Seek(0, soBeginning);

          Total := TamSector div 2048;
          if TamSector mod 2048 <> 0 then Total := Total+1;

          for j := 0 to Total-1 do
          begin
           MemBuf.Seek(j*2048,soBeginning); 
           while not (MemBuf.Position >= (j+1)*2048) do
           begin
                new(xFichero);
                Fillchar(xFichero^, sizeof(xFichero^), $00);

                xFichero.pIzq := $FFFF;

                MemBuf.Read(xFichero^,14);
                MemBuf.Read(xFichero.Nombre,xFichero.LongNombre);
                pNombre := @xFichero.Nombre;
                xFichero.DirPadre := i;

                if (xFichero.pIzq = $FFFF) then break;
                xIISO.Lista.Add(xFichero);    

                if ((xFichero.Atributo and XF_DIRECTORIO) = XF_DIRECTORIO) then
                begin
                   xIISO.numCarpetas := xIISO.numCarpetas + 1;
                   Numero := Numero+1;
                   if (xFichero.Tamano <> 0) and (xFichero.SectorIn <> 0) then
                   begin
                        xFichero.DirHijo := Numero;
                        LeerTablaFicheros(xFichero.SectorIn+IMG_SECTOR-32, xFichero.Tamano, Numero, Fichero);
                   end
                   else
                        xFichero.DirHijo := -1;
                end
                else
                begin
                     xIISO.tamISO := xIISO.tamISO + xFichero.Tamano;
                     xIISO.numFicheros := xIISO.numFicheros + 1;
                end;

                if ((MemBuf.Position mod 4) <> 0) then
                  MemBuf.Seek(MemBuf.Position+4-(MemBuf.Position mod 4),soBeginning);
           end;
          end;
     end;
     MemBuf.Free;
end;

function AbrirXISO(imagen: string): boolean;
var
   Fichero: TFilestream;
   i,NumIni: int64;
begin
        NumIni := 0;
        Result := False;
        Fichero := TFilestream.Create(imagen, fmOpenRead or fmShareDenyNone);
        with Fichero do
        begin
                Seek(IMG_SECTOR*TAM_SECTOR, soBeginning);
                Read(xIISO.xVD, sizeof(xIISO.xVD));

                if (xIISO.xVD.IDIn <> XBOX_MEDIA) or
                   (xIISO.xVD.IDOut <> XBOX_MEDIA) then
                begin
                     Result := False;
                     Fichero.Free;
                     Exit;
                end;

                if xIISO.Lista = nil then
                   xIISO.Lista := TList.Create
                else
                   xIISO.Lista.Clear;

                xIISO.numFicheros := 0;
                xIISO.numCarpetas := 0;
                xIISO.tamISO := 0;
                LeerTablaFicheros(xIISO.xVD.DirRaiz+IMG_SECTOR-32, xIISO.xVD.TamRaiz, NumIni, Fichero);
        end;
        Result := True;
        Fichero.Free;
end;

{ FIN SECCION DE LECTURA DESDE IMAGEN }

{ SECCION DE LECTURA DESDE DVD }

procedure ExtraerFicheroXDVD(HA,SCSI,LUN: byte;Unidad: TCDROM; grabar: string; Sector, tamano: int64);
var
   fguardar: TFilestream;
   i,fin,entero,resto,a: int64;
   buffer: array[0..32767] of byte;
   r: integer;
 function Tamano2Sector(Tamano: int64): int64;
 begin
      result := Tamano div TAM_SECTOR;
      if ((Tamano mod TAM_SECTOR) <> 0) then result := result+1;
 end;
begin
     sector := sector+CDDVD_VD-32;
     fguardar := TFilestream.Create(grabar, fmCreate or fmShareDenyNone);

     Entero := (Tamano2Sector(Tamano) div $10)*$10;
     Resto := (Tamano2Sector(Tamano) mod $10);

     a := Sector;
     if (Entero <> 0) then
       while (a < Sector+Entero) do
       begin
            if not Unidad.Read12(HA,SCSI,LUN,a,a+$10,@Buffer) then
            begin
                MessageBox(0,'Error de lectura.','Error',MB_OK or MB_ICONERROR);
                fguardar.Free;
                exit;
            end;
            fguardar.Write(buffer, sizeof(buffer));
            a := a+$10;
       end;

     if (Resto <> 0) then
     begin
          if not Unidad.Read12(HA,SCSI,LUN,a,a+Resto,@Buffer) then exit;
          r := (TAM_SECTOR - (Tamano mod TAM_SECTOR)) mod 2048;
          fguardar.Write(buffer,Resto*TAM_SECTOR-r);
     end;

     fguardar.Free;
end;

procedure LeerTablaFicherosXDVD(HA,SCSI,LUN: byte; Unidad: TCDROM; Sector: int64; TamSector: int64; var Numero: int64);
type
   PByteBuffer = ^TByteBuffer;
   TByteBuffer = array[0..65535] of byte;
var
   MemBuf: TMemoryStream;
   xFichero: pxFichero;
   pNombre: PChar;
   i: int64;
   SectoresLeer: integer;
   Buffer: PByteBuffer;
   Total,j: integer;
begin
     if (Sector = $FFFFFFFFFFFFFFFF) then Exit
     else
     begin
          i := Numero;
          // Calculamos el numero de sectores a leer
          SectoresLeer := TamSector div TAM_SECTOR;
          if ((TamSector mod TAM_SECTOR) <> 0) then SectoresLeer := SectoresLeer+1;

          new(Buffer);
          
          // Leemos el sector
          if not Unidad.Read12(HA,SCSI,LUN,Sector,Sector+SectoresLeer,Buffer) then exit;
          MemBuf := TMemoryStream.Create();
          try
             MemBuf.Write(Buffer^,SectoresLeer*TAM_SECTOR);
          except end;
          MemBuf.Seek(0, soBeginning);

          Total := 0;
          Total := TamSector div 2048;
          if TamSector mod 2048 <> 0 then Total := Total+1;

          for j := 0 to Total-1 do
          begin
           MemBuf.Seek(j*2048,soBeginning);
           while not (MemBuf.Position >= (j+1)*2048) do//MemBuf.Size) do
           begin
                new(xFichero);
                Fillchar(xFichero^, sizeof(xFichero^), $00);
                xFichero.pIzq := $FFFF;
                MemBuf.Read(xFichero^,14);
                MemBuf.Read(xFichero.Nombre,xFichero.LongNombre);
                pNombre := @xFichero.Nombre;
                xFichero.DirPadre := i;

                if (xFichero.pIzq = $FFFF) then break;
                xIISO.Lista.Add(xFichero);

                if ((xFichero.Atributo and XF_DIRECTORIO) = XF_DIRECTORIO) then
                begin
                   xIISO.numCarpetas := xIISO.numCarpetas + 1;
                   Numero := Numero+1;

                   // Si el Directorio NO esta Vacio entonces lo procesamos
                   if (xFichero.Tamano <> 0) and (xFichero.SectorIn <> 0) then
                   begin
                        xFichero.DirHijo := Numero;
                        LeerTablaFicherosXDVD(HA,SCSI,LUN,Unidad,xFichero.SectorIn+CDDVD_VD-32, xFichero.Tamano, Numero);
                   end
                   else
                       xFichero.DirHijo := -1;
                end
                else
                begin
                     xIISO.tamISO := xIISO.tamISO + xFichero.Tamano;
                     xIISO.numFicheros := xIISO.numFicheros + 1;
                end;

                // Avanzamos hasta la posicion DWORD siguiente
                if ((MemBuf.Position mod 4) <> 0) then
                   MemBuf.Seek(MemBuf.Position+4-(MemBuf.Position mod 4),soBeginning);
           end;
          end;
     end;
     MemBuf.Free;
     Dispose(Buffer);
end;

function LeerXDVD(HA,SCSI,LUN: byte; Unidad: TCDROM): boolean;
var
   Mem: TMemoryStream;
   i,NumIni: int64;
   Buffer: array[0..2047] of byte;
   Alternativo: boolean;
begin
        NumIni := 0;
        result := False;
        Alternativo := False;

        CDDVD_VD := DVD_SECTOR;
        if Unidad.Read12(HA,SCSI,LUN,CDDVD_VD,CDDVD_VD+1,@Buffer) then
        begin
             Mem := TMemoryStream.Create;
             Mem.Write(Buffer,sizeof(Buffer));
             Mem.Seek(0,soFromBeginning);
             Mem.Read(xIISO.xVD, sizeof(xIISO.xVD));
             Mem.Free;
             if (xIISO.xVD.IDIn <> XBOX_MEDIA) or (xIISO.xVD.IDOut <> XBOX_MEDIA) then
                Alternativo := True;
        end
        else Alternativo := True;

        if Alternativo then
        begin
             CDDVD_VD := CD_SECTOR;
             if not Unidad.Read12(HA,SCSI,LUN,CDDVD_VD,CDDVD_VD+1,@Buffer) then exit;
             Mem := TMemoryStream.Create;
             Mem.Write(Buffer,sizeof(Buffer));
             Mem.Seek(0,soBeginning);
             Mem.Read(xIISO.xVD, sizeof(xIISO.xVD));
             Mem.Free;
             if (xIISO.xVD.IDIn <> XBOX_MEDIA) or (xIISO.xVD.IDOut <> XBOX_MEDIA) then Exit;
        end;

        if xIISO.Lista = nil then
           xIISO.Lista := TList.Create
        else
           xIISO.Lista.Clear;

        xIISO.numFicheros := 0;
        XIISO.numCarpetas := 0;
        xIISO.tamISO := 0;
        LeerTablaFicherosXDVD(HA,SCSI,LUN,Unidad,xIISO.xVD.DirRaiz+CDDVD_VD-32, xIISO.xVD.TamRaiz, NumIni);

        result := True;    
end;

{ FIN SECCION DE LECTURA DESDE DVD }

end.