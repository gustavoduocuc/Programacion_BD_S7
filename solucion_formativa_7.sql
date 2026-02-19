/*==========================================================
  Sistema MAXSALUD – Automatización de Morosidad Anual
  Autores: Gustavo Dominguez y Alonso Basualdo
==========================================================*/
/*==========================================================
  Secuencia y Trigger como: Auditoria de errores
==========================================================*/

CREATE SEQUENCE SQE_ERR_PROCESO
START WITH 1
INCREMENT BY 1;
/

CREATE OR REPLACE TRIGGER TRG_AUDITA_ERRO
BEFORE INSERT ON ERRORES_PROCESO
FOR EACH ROW
BEGIN
    :NEW.nro_correlativo := SQE_ERR_PROCESO.NEXTVAL;
END;
/

/*==========================================================
  PKG: Reglas de descuento por 3ra edad + variables compartidas
==========================================================*/
CREATE OR REPLACE PACKAGE PKG_MXSALUD_MOROSIDAD IS
    -- Variables públicas (se pueden leer/modificar desde fuera del package)
    g_valor_multa     NUMBER;
    g_valor_descuento NUMBER;

    -- Función pública: obtiene el % de descuento según edad (>70)
    FUNCTION FN_OBT_DESC_3RA_EDAD(p_edad NUMBER) RETURN NUMBER;
END PKG_MXSALUD_MOROSIDAD;
/

CREATE OR REPLACE PACKAGE BODY PKG_MXSALUD_MOROSIDAD IS

    FUNCTION FN_OBT_DESC_3RA_EDAD(p_edad NUMBER) RETURN NUMBER IS
        v_porcentaje NUMBER;
    BEGIN
        /*
          Buscamos el tramo donde cae la edad.
          Importante: si por diseño existieran tramos solapados, nos quedamos con el tramo
          más “específico” (por ejemplo, el que tiene mayor anno_ini).
        */
        SELECT porcentaje_descto
          INTO v_porcentaje
          FROM (
                SELECT porcentaje_descto
                  FROM porc_descto_3ra_edad
                 WHERE p_edad BETWEEN anno_ini AND anno_ter
                 ORDER BY anno_ini DESC
               )
         WHERE ROWNUM = 1;

        RETURN NVL(v_porcentaje, 0);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0; -- no hay descuento configurado para esa edad
        WHEN OTHERS THEN
            -- si algo falla, por seguridad no aplicamos descuento
            RETURN 0;
    END FN_OBT_DESC_3RA_EDAD;

END PKG_MXSALUD_MOROSIDAD;
/

/*==========================================================
  FN: Obtiene nombre de especialidad de una atención
==========================================================*/
CREATE OR REPLACE FUNCTION FN_OBT_NOMBRE_ESPECIALIDAD(p_ate_id NUMBER)
RETURN VARCHAR2
IS
    v_nombre_especialidad VARCHAR2(100);
BEGIN
    SELECT e.nombre
      INTO v_nombre_especialidad
      FROM atencion a
      JOIN medico m       ON a.med_run = m.med_run
      JOIN especialidad e ON m.esp_id = e.esp_id
     WHERE a.ate_id = p_ate_id;

    RETURN v_nombre_especialidad;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'SIN ESPECIALIDAD';
    WHEN OTHERS THEN
        RETURN 'ERROR ESPECIALIDAD';
END;
/

/*==========================================================
  SP: Genera PAGO_MOROSO para el año anterior al proceso
==========================================================*/
CREATE OR REPLACE PROCEDURE SP_GENERA_PAGO_MOROSO(p_fecha_proceso DATE)
IS
    -- Año objetivo: si ejecuto en 2023, proceso 2022 (según enunciado)
    v_anno_objetivo NUMBER(4);

    -- VARRAY con multas por día según especialidad.
    -- OJO: aquí aprovechamos que los ID de especialidad son 1..9 (según script).
    TYPE t_multas_dia IS VARRAY(9) OF NUMBER(8);

    v_multas_por_dia t_multas_dia := t_multas_dia(
        1300, -- 1 Traumatología
        2000, -- 2 Gastroenterología
        1700, -- 3 Neurología
        1100, -- 4 Geriatría
        1900, -- 5 Oftalmología
        1700, -- 6 Pediatría
        1200, -- 7 Medicina General
        2000, -- 8 Ginecología
        2300  -- 9 Dermatología
    );

    -- Variables de cálculo por cada atención
    v_dias_morosidad     NUMBER;
    v_multa_dia          NUMBER;
    v_multa_base         NUMBER;
    v_multa_final        NUMBER;
    v_edad               NUMBER;
    v_descuento_pct      NUMBER;
    v_obs                VARCHAR2(200);
    
    -- Variable para almacenar nombre real de la especialidad
    v_nombre_especialidad VARCHAR2(100);
    -- Solo para comparar
    v_nombre_especialidad_cmp   VARCHAR2(100);
    --Variable para guardar errores
    v_err_msg   VARCHAR2(500);

    -- Cursor con las atenciones pagadas fuera de plazo del año objetivo
    CURSOR c_morosos IS
        SELECT
            p.pac_run,
            p.dv_run,
            p.pnombre,
            p.snombre,
            p.apaterno,
            p.amaterno,
            p.fecha_nacimiento,
            a.ate_id,
            a.fecha_atencion,
            a.costo,
            pa.fecha_venc_pago,
            pa.fecha_pago,
            m.esp_id
        FROM pago_atencion pa
        JOIN atencion a  ON pa.ate_id = a.ate_id
        JOIN paciente p  ON a.pac_run = p.pac_run
        JOIN medico m    ON a.med_run = m.med_run
        WHERE EXTRACT(YEAR FROM pa.fecha_venc_pago) = v_anno_objetivo
          AND pa.fecha_pago > pa.fecha_venc_pago
        ORDER BY pa.fecha_venc_pago ASC, p.apaterno ASC;

BEGIN
    -- 1) Preparamos el año que corresponde procesar (año anterior)
    v_anno_objetivo := EXTRACT(YEAR FROM p_fecha_proceso) - 1;

    -- 2) Limpieza de la tabla de salida para regenerar el reporte completo
    EXECUTE IMMEDIATE 'TRUNCATE TABLE PAGO_MOROSO';

    -- 3) Recorremos cada atención morosa y calculamos multa/desc
    FOR reg IN c_morosos LOOP

        -- Días de atraso (siempre entero)
        v_dias_morosidad := TRUNC(reg.fecha_pago) - TRUNC(reg.fecha_venc_pago);

        -- Multa por día según especialidad usando el VARRAY
        -- Determinamos la multa según nombre de especialidad
        -- Obtenemos el nombre real (como viene en la tabla)
        v_nombre_especialidad := FN_OBT_NOMBRE_ESPECIALIDAD(reg.ate_id);
        
        -- Creamos versión normalizada solo para comparación y evitar problemas de diferencias entre mayusculas y minusculas)=
        v_nombre_especialidad_cmp := UPPER(TRIM(v_nombre_especialidad));
        
        IF v_nombre_especialidad_cmp = 'TRAUMATOLOGIA' THEN
            v_multa_dia := v_multas_por_dia(1);
        ELSIF v_nombre_especialidad_cmp = 'GASTROENTEROLOGIA' THEN
            v_multa_dia := v_multas_por_dia(2);
        ELSIF v_nombre_especialidad_cmp = 'NEUROLOGIA' THEN
            v_multa_dia := v_multas_por_dia(3);
        ELSIF v_nombre_especialidad_cmp = 'GERIATRIA' THEN
            v_multa_dia := v_multas_por_dia(4);
        ELSIF v_nombre_especialidad_cmp = 'OFTALMOLOGIA' THEN
            v_multa_dia := v_multas_por_dia(5);
        ELSIF v_nombre_especialidad_cmp = 'PEDIATRIA' THEN
            v_multa_dia := v_multas_por_dia(6);
        ELSIF v_nombre_especialidad_cmp = 'MEDICINA GENERAL' THEN
            v_multa_dia := v_multas_por_dia(7);
        ELSIF v_nombre_especialidad_cmp = 'GINECOLOGIA' THEN
            v_multa_dia := v_multas_por_dia(8);
        ELSIF v_nombre_especialidad_cmp = 'DERMATOLOGIA' THEN
            v_multa_dia := v_multas_por_dia(9);
        ELSE
            v_multa_dia := 0;
        END IF;

        -- Monto base sin descuento
        v_multa_base := v_dias_morosidad * v_multa_dia;

        -- Guardamos en variable pública del package
        PKG_MXSALUD_MOROSIDAD.g_valor_multa := v_multa_base;

        -- Edad del paciente a la fecha de la atención 
        v_edad := TRUNC(MONTHS_BETWEEN(reg.fecha_atencion, reg.fecha_nacimiento) / 12);

        -- Por defecto asumimos sin descuento
        v_descuento_pct := 0;
        v_multa_final   := v_multa_base;
        v_obs           := null;

        -- Regla: Beneficio especial si tiene más de 70
        IF v_edad > 70 THEN
            v_descuento_pct := PKG_MXSALUD_MOROSIDAD.FN_OBT_DESC_3RA_EDAD(v_edad);
            PKG_MXSALUD_MOROSIDAD.g_valor_descuento := v_descuento_pct;

            -- Aplicamos descuento solo si viene un % mayor que 0
            IF v_descuento_pct > 0 THEN
                v_multa_final := ROUND(v_multa_base * (1 - (v_descuento_pct / 100)));
                -- Se incluyó el porcentaje de descuento para ser aun mas especificos
                v_obs := 'Paciente tenia ' || v_edad || ' a la fecha de atención. Se aplicó descuento ' || v_descuento_pct || '% paciente mayor a 70 años';
            ELSE
                v_obs := 'Paciente > 70, pero sin tramo de descuento configurado';
            END IF;
        ELSE
            -- Si no es >70, aseguramos que el package quede coherente también
            PKG_MXSALUD_MOROSIDAD.g_valor_descuento := 0;
        END IF;

        -- Insert final en la tabla solicitada por el Ministerio
        INSERT INTO pago_moroso (
            pac_run,
            pac_dv_run,
            pac_nombre,
            ate_id,
            fecha_venc_pago,
            fecha_pago,
            dias_morosidad,
            especialidad_atencion,
            costo_atencion,
            monto_multa,
            observacion
        ) VALUES (
            reg.pac_run,
            reg.dv_run,
            INITCAP(reg.pnombre || ' ' || reg.snombre || ' ' || reg.apaterno || ' ' || reg.amaterno),
            reg.ate_id,
            reg.fecha_venc_pago,
            reg.fecha_pago,
            v_dias_morosidad,
            v_nombre_especialidad,
            reg.costo,
            v_multa_final,
            v_obs
        );

    END LOOP;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        v_err_msg := SUBSTR(SQLERRM, 1, 500);
        INSERT INTO ERRORES_PROCESO (subprograma_error, descripcion_error)
        VALUES('SP_GENERA_PAGO_MOROSO', v_err_msg);
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Error en SP_GENERA_PAGO_MOROSO: ' || SQLERRM);
        RAISE;
END;
/

/* =======================================================
---                Pruebas de ejecución
=========================================================*/

SET SERVEROUTPUT ON;

BEGIN
    SP_GENERA_PAGO_MOROSO(SYSDATE);
END;
/

SELECT *
FROM PAGO_MOROSO
ORDER BY FECHA_VENC_PAGO ASC, PAC_NOMBRE ASC;


-- Consultamos la tabla de errores para revisar si se documento el error incorporado como prueba manual
SELECT * FROM ERRORES_PROCESO;


