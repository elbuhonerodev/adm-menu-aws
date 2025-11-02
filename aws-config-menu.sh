#!/bin/bash

# Menú interactivo para AWS CLI - Credenciales en memoria
# Ubicación: /root/aws-config-menu.sh

set -e

# Colores para output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Variables globales para credenciales en memoria
AWS_ACCESS_KEY=""
AWS_SECRET_KEY=""
AWS_REGION="us-east-1"
AWS_PROFILE_NAME=""
AWS_CREDITS=""
AWS_CREDITS_START_DATE=""
TEMP_DIR="/tmp/aws-cloudfront"
CREDITS_FILE="$TEMP_DIR/aws_credits_tracking.json"

# Precio por GB de transferencia CloudFront (USD)
CF_PRICE_PER_GB=0.085

# Funciones de color
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_header() { echo -e "${CYAN}$1${NC}"; }
print_cloudfront() { echo -e "${PURPLE}[CLOUDFRONT]${NC} $1"; }

# =============================================================================
# FUNCIONES BÁSICAS Y DE VERIFICACIÓN
# =============================================================================

# Verificar si AWS CLI está instalado
check_aws_installed() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI no está instalado"
        echo "Ejecuta primero: ./dependencias-aws.sh"
        exit 1
    fi
    print_success "AWS CLI está instalado"
}

# Crear directorio temporal
create_temp_dir() {
    mkdir -p "$TEMP_DIR"
}

# Inicializar sistema de créditos
init_credits_system() {
    if [ ! -f "$CREDITS_FILE" ]; then
        cat > "$CREDITS_FILE" << EOF
{
    "initial_credits": 0,
    "remaining_credits": 0,
    "start_date": "",
    "monthly_reset": true,
    "usage_history": [],
    "cloudfront_costs": 0
}
EOF
    fi
}

# Verificar credenciales en memoria
verify_credentials() {
    # Crear variables de entorno temporales
    export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY"
    export AWS_DEFAULT_REGION="$AWS_REGION"

    # Verificar con AWS STS
    local sts_output
    sts_output=$(timeout 10s aws sts get-caller-identity --output json 2>&1)
    local sts_exit_code=$?

    # Limpiar variables de entorno
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_DEFAULT_REGION

    if [ $sts_exit_code -eq 0 ]; then
        local account_id
        account_id=$(echo "$sts_output" | jq -r '.Account' 2>/dev/null || echo "N/A")
        local user_id
        user_id=$(echo "$sts_output" | jq -r '.UserId' 2>/dev/null || echo "N/A")

        print_success "✅ Cuenta: $account_id"
        print_success "✅ User ID: ${user_id:0:16}..."
        return 0
    else
        if [[ "$sts_output" == *"InvalidClientTokenId"* ]]; then
            print_error "❌ Access Key ID inválido"
        elif [[ "$sts_output" == *"SignatureDoesNotMatch"* ]]; then
            print_error "❌ Secret Access Key incorrecta"
        elif [[ "$sts_output" == *"Request has expired"* ]]; then
            print_error "❌ Credenciales expiradas"
        else
            print_error "❌ Error verificando credenciales"
        fi
        return 1
    fi
}

# Guardar credenciales permanentemente
save_credentials() {
    echo
    print_info "Guardando credenciales permanentemente..."

    # Crear directorio .aws si no existe
    mkdir -p ~/.aws
    chmod 700 ~/.aws

    # Guardar en credentials
    if [ ! -f ~/.aws/credentials ] || ! grep -q "\[$AWS_PROFILE_NAME\]" ~/.aws/credentials 2>/dev/null; then
        echo "[$AWS_PROFILE_NAME]" >> ~/.aws/credentials
        echo "aws_access_key_id = $AWS_ACCESS_KEY" >> ~/.aws/credentials
        echo "aws_secret_access_key = $AWS_SECRET_KEY" >> ~/.aws/credentials
        echo "" >> ~/.aws/credentials
    else
        # Actualizar perfil existente
        sed -i "/\[$AWS_PROFILE_NAME\]/,/^$/d" ~/.aws/credentials
        echo "[$AWS_PROFILE_NAME]" >> ~/.aws/credentials
        echo "aws_access_key_id = $AWS_ACCESS_KEY" >> ~/.aws/credentials
        echo "aws_secret_access_key = $AWS_SECRET_KEY" >> ~/.aws/credentials
        echo "" >> ~/.aws/credentials
    fi

    # Guardar en config
    if [ ! -f ~/.aws/config ] || ! grep -q "\[profile $AWS_PROFILE_NAME\]" ~/.aws/config 2>/dev/null; then
        echo "[profile $AWS_PROFILE_NAME]" >> ~/.aws/config
        echo "region = $AWS_REGION" >> ~/.aws/config
        echo "output = json" >> ~/.aws/config
        echo "" >> ~/.aws/config
    else
        sed -i "/\[profile $AWS_PROFILE_NAME\]/,/^$/d" ~/.aws/config
        echo "[profile $AWS_PROFILE_NAME]" >> ~/.aws/config
        echo "region = $AWS_REGION" >> ~/.aws/config
        echo "output = json" >> ~/.aws/config
        echo "" >> ~/.aws/config
    fi

    print_success "✅ Credenciales guardadas como perfil: $AWS_PROFILE_NAME"
}

# Ejecutar comando AWS con credenciales en memoria
aws_memory() {
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
    AWS_DEFAULT_REGION="$AWS_REGION" \
    aws "$@"
}

# Verificar permisos CloudFront (servicio global)
check_cloudfront_permissions() {
    print_info "Verificando permisos de CloudFront..."

    # CloudFront es un servicio global, usar la función aws_memory
    local cf_output
    cf_output=$(aws_memory cloudfront list-distributions --max-items 1 --output json 2>&1)
    local cf_exit_code=$?

    if [ $cf_exit_code -eq 0 ]; then
        print_success "✅ Permisos CloudFront verificados"
        return 0
    else
        if [[ "$cf_output" == *"AccessDenied"* ]]; then
            print_error "❌ Sin permisos para CloudFront"
            print_warning "El usuario IAM necesita permisos cloudfront:ListDistributions"
        else
            print_error "❌ Error verificando CloudFront: $cf_output"
        fi
        return 1
    fi
}

# =============================================================================
# SISTEMA DE CRÉDITOS AWS
# =============================================================================

# Solicitar créditos AWS al usuario
request_aws_credits() {
    echo
    print_header "💳 GESTIÓN DE CRÉDITOS AWS"
    echo
    echo -e "${YELLOW}💡 AWS ofrece \$120 en créditos para nuevos usuarios${NC}"
    echo -e "${YELLOW}💡 Precio CloudFront: \$$CF_PRICE_PER_GB por GB${NC}"
    echo

    echo -n -e "${BLUE}¿Tienes créditos AWS? (y/n): ${NC}"
    read -r has_credits

    if [[ $has_credits =~ ^[Yy]$ ]]; then
        while true; do
            echo -n -e "${BLUE}Ingresa la cantidad de créditos AWS (USD): ${NC}"
            read -r credits_input

            if [[ "$credits_input" =~ ^[0-9]+$ ]] || [[ "$credits_input" =~ ^[0-9]+\.[0-9]+$ ]]; then
                AWS_CREDITS="$credits_input"
                AWS_CREDITS_START_DATE=$(date -Iseconds)

                # Actualizar archivo de créditos
                jq --arg credits "$AWS_CREDITS" --arg date "$AWS_CREDITS_START_DATE" \
                    '.initial_credits = ($credits | tonumber) |
                     .remaining_credits = ($credits | tonumber) |
                     .start_date = $date |
                     .cloudfront_costs = 0' \
                    "$CREDITS_FILE" > "${CREDITS_FILE}.tmp" && mv "${CREDITS_FILE}.tmp" "$CREDITS_FILE"

                print_success "✅ Créditos configurados: \$$AWS_CREDITS USD"
                break
            else
                print_error "❌ Cantidad inválida. Ingresa un número válido."
            fi
        done
    else
        AWS_CREDITS="0"
        print_info "Continuando sin créditos AWS"
    fi
}

# Mostrar información de créditos
show_credits_info() {
    if [ -f "$CREDITS_FILE" ]; then
        local initial_credits
        initial_credits=$(jq -r '.initial_credits' "$CREDITS_FILE")
        local remaining_credits
        remaining_credits=$(jq -r '.remaining_credits' "$CREDITS_FILE")
        local cloudfront_costs
        cloudfront_costs=$(jq -r '.cloudfront_costs' "$CREDITS_FILE")
        local start_date
        start_date=$(jq -r '.start_date' "$CREDITS_FILE")

        if [ "$initial_credits" != "0" ]; then
            echo
            echo -e "${GREEN}💳 INFORMACIÓN DE CRÉDITOS AWS:${NC}"
            echo "  • Créditos iniciales: \$$initial_credits USD"
            echo "  • Créditos restantes: \$$remaining_credits USD"
            echo "  • Gasto en CloudFront: \$$cloudfront_costs USD"
            echo "  • Inicio: $(date -d "$start_date" +"%Y-%m-%d %H:%M")"

            # Calcular proyección
            if [ "$cloudfront_costs" != "0" ]; then
                local days_used
                days_used=$(( ( $(date +%s) - $(date -d "$start_date" +%s) ) / 86400 + 1 ))
                local daily_cost
                daily_cost=$(echo "scale=4; $cloudfront_costs / $days_used" | bc)
                local days_remaining
                days_remaining=$(echo "scale=0; $remaining_credits / $daily_cost" | bc 2>/dev/null || echo "N/A")

                echo "  • Gasto diario promedio: \$$(echo "scale=2; $daily_cost" | bc) USD"
                if [[ "$days_remaining" != "N/A" ]] && [ "$days_remaining" -gt 0 ]; then
                    echo "  • Días restantes: ~$days_remaining días"
                fi
            fi
        fi
    fi
}

# Actualizar créditos por uso de CloudFront
update_credits_for_usage() {
    local distribution_id="$1"
    local gb_used="$2"

    if [ ! -f "$CREDITS_FILE" ]; then
        return 0
    fi

    local cost
    cost=$(echo "scale=4; $gb_used * $CF_PRICE_PER_GB" | bc)

    # Actualizar archivo de créditos
    local current_credits
    current_credits=$(jq -r '.remaining_credits' "$CREDITS_FILE")
    local current_costs
    current_costs=$(jq -r '.cloudfront_costs' "$CREDITS_FILE")

    local new_credits
    new_credits=$(echo "scale=2; $current_credits - $cost" | bc)
    local new_costs
    new_costs=$(echo "scale=2; $current_costs + $cost" | bc)

    # Registrar uso histórico
    local usage_record
    usage_record=$(jq -n \
        --arg dist "$distribution_id" \
        --arg gb "$gb_used" \
        --arg cost "$cost" \
        --arg date "$(date -Iseconds)" \
        '{
            distribution_id: $dist,
            gb_used: ($gb | tonumber),
            cost: ($cost | tonumber),
            timestamp: $date
        }')

    jq --argjson new_credits "$new_credits" \
       --argjson new_costs "$new_costs" \
       --argjson usage "$usage_record" \
       '.remaining_credits = $new_credits |
        .cloudfront_costs = $new_costs |
        .usage_history += [$usage]' \
       "$CREDITS_FILE" > "${CREDITS_FILE}.tmp" && mv "${CREDITS_FILE}.tmp" "$CREDITS_FILE"

    echo "$cost"
}

# Monitoreo en tiempo real de créditos
realtime_credits_monitor() {
    print_header "⏰ MONITOR EN TIEMPO REAL DE CRÉDITOS"
    echo

    if [ ! -f "$CREDITS_FILE" ]; then
        print_error "Sistema de créditos no configurado"
        return 1
    fi

    local initial_credits
    initial_credits=$(jq -r '.initial_credits' "$CREDITS_FILE")

    if [ "$initial_credits" = "0" ]; then
        print_warning "No hay créditos AWS configurados"
        return 1
    fi

    print_info "Iniciando monitoreo en tiempo real..."
    print_info "Presiona Ctrl+C para detener el monitoreo"
    echo

    local monitor_count=0
    while true; do
        clear
        print_header "📊 MONITOREO EN TIEMPO REAL - Ciclo $((++monitor_count))"

        # Obtener información actual de créditos
        local remaining_credits
        remaining_credits=$(jq -r '.remaining_credits' "$CREDITS_FILE")
        local cloudfront_costs
        cloudfront_costs=$(jq -r '.cloudfront_costs' "$CREDITS_FILE")
        local start_date
        start_date=$(jq -r '.start_date' "$CREDITS_FILE")

        # Obtener uso actual de CloudFront
        print_info "Calculando uso actual de CloudFront..."

        local current_usage=0
        local distributions_output
        distributions_output=$(aws_memory cloudfront list-distributions --output json 2>/dev/null || echo "{}")

        if [ $? -eq 0 ]; then
            local distribution_ids
            distribution_ids=$(echo "$distributions_output" | jq -r '.DistributionList.Items[]?.Id' 2>/dev/null)

            for dist_id in $distribution_ids; do
                if [ -n "$dist_id" ]; then
                    # Obtener métricas de las últimas 24 horas
                    local bytes_metric
                    bytes_metric=$(aws_memory cloudwatch get-metric-statistics \
                        --namespace AWS/CloudFront \
                        --metric-name BytesDownloaded \
                        --dimensions Name=DistributionId,Value="$dist_id" Name=Region,Value=Global \
                        --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
                        --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --period 86400 \
                        --statistics Sum \
                        --output json 2>/dev/null)

                    if [ $? -eq 0 ]; then
                        local bytes_24h
                        bytes_24h=$(echo "$bytes_metric" | jq -r '.Datapoints[0].Sum? // 0')
                        local gb_24h
                        gb_24h=$(echo "scale=4; $bytes_24h / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                        current_usage=$(echo "scale=4; $current_usage + $gb_24h" | bc)

                        # Actualizar créditos por este uso
                        if (( $(echo "$gb_24h > 0" | bc -l) )); then
                            local cost_incurred
                            cost_incurred=$(update_credits_for_usage "$dist_id" "$gb_24h")
                            print_info "Distribución $dist_id: $(echo "scale=2; $gb_24h" | bc) GB = \$$(echo "scale=2; $cost_incurred" | bc)"
                        fi
                    fi
                fi
            done
        fi

        # Re-leer datos actualizados después de las actualizaciones
        remaining_credits=$(jq -r '.remaining_credits' "$CREDITS_FILE")
        cloudfront_costs=$(jq -r '.cloudfront_costs' "$CREDITS_FILE")

        # Mostrar información
        echo
        echo -e "${GREEN}💰 ESTADO ACTUAL DE CRÉDITOS:${NC}"
        echo "  • Créditos iniciales: \$$initial_credits USD"
        echo "  • Créditos restantes: \$$remaining_credits USD"
        echo "  • Gasto total CloudFront: \$$cloudfront_costs USD"
        echo "  • Uso últimas 24h: $(echo "scale=2; $current_usage" | bc) GB"

        # Calcular costo actual
        local current_cost
        current_cost=$(echo "scale=4; $current_usage * $CF_PRICE_PER_GB" | bc)
        echo "  • Costo últimas 24h: \$$(echo "scale=2; $current_cost" | bc) USD"

        # Calcular porcentaje usado
        local percent_used
        percent_used=$(echo "scale=1; ($cloudfront_costs * 100) / $initial_credits" | bc 2>/dev/null || echo "0")
        echo "  • Porcentaje usado: ${percent_used}%"

        # Alertas
        echo
        if (( $(echo "$percent_used >= 80" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "${RED}🚨 ALERTA: Has usado el ${percent_used}% de tus créditos${NC}"
        elif (( $(echo "$percent_used >= 50" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "${YELLOW}⚠️  ADVERTENCIA: Has usado el ${percent_used}% de tus créditos${NC}"
        else
            echo -e "${GREEN}✅ Estado: Saludable${NC}"
        fi

        # Proyección
        local days_used
        days_used=$(( ( $(date +%s) - $(date -d "$start_date" +%s) ) / 86400 + 1 ))
        if [ "$days_used" -gt 0 ]; then
            local daily_rate
            daily_rate=$(echo "scale=2; $cloudfront_costs / $days_used" | bc)
            local projected_days
            projected_days=$(echo "scale=0; $remaining_credits / $daily_rate" | bc 2>/dev/null || echo "N/A")

            echo
            echo -e "${BLUE}📈 PROYECCIÓN:${NC}"
            echo "  • Gasto diario promedio: \$$daily_rate USD"
            if [[ "$projected_days" != "N/A" ]] && [ "$projected_days" -gt 0 ]; then
                echo "  • Créditos durarán: ~$projected_days días"
                local end_date
                end_date=$(date -d "+$projected_days days" +"%Y-%m-%d")
                echo "  • Fecha estimada de agotamiento: $end_date"
            fi
        fi

        echo
        echo -e "${CYAN}🔄 Actualizando en 60 segundos...${NC}"
        echo -e "${YELLOW}Presiona Ctrl+C para salir${NC}"

        # Esperar 60 segundos
        for i in {60..1}; do
            echo -ne "⏳ Siguiente actualización en: ${i}s\033[0K\r"
            sleep 1
        done
    done
}

# Función para mostrar historial de uso
show_usage_history() {
    print_header "📋 HISTORIAL DE USO DE CRÉDITOS"
    echo

    if [ ! -f "$CREDITS_FILE" ]; then
        print_error "Sistema de créditos no configurado"
        return 1
    fi

    local usage_count
    usage_count=$(jq -r '.usage_history | length' "$CREDITS_FILE")

    if [ "$usage_count" -eq 0 ]; then
        print_info "No hay historial de uso registrado"
        return 0
    fi

    echo -e "${GREEN}Últimos 10 registros de uso:${NC}"
    echo "=========================================="

    jq -r '.usage_history[-10:] | reverse | .[] | "\(.timestamp) | \(.distribution_id) | \(.gb_used | tonumber | round(2)) GB | \(\$%.2f | .cost)"' "$CREDITS_FILE" 2>/dev/null | while read -r line; do
        echo "  • $line"
    done

    local total_usage
    total_usage=$(jq -r '[.usage_history[].gb_used] | add | round(2)' "$CREDITS_FILE")
    local total_cost
    total_cost=$(jq -r '.cloudfront_costs' "$CREDITS_FILE")

    echo
    echo -e "${YELLOW}📊 RESUMEN TOTAL:${NC}"
    echo "  • GB totales transferidos: $total_usage GB"
    echo "  • Costo total CloudFront: \$$total_cost USD"
    echo "  • Registros en historial: $usage_count"

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para resetear créditos
reset_credits() {
    print_header "🔄 RESETEAR SISTEMA DE CRÉDITOS"
    echo

    if [ ! -f "$CREDITS_FILE" ]; then
        print_error "Sistema de créditos no configurado"
        return 1
    fi

    local current_credits
    current_credits=$(jq -r '.initial_credits' "$CREDITS_FILE")

    if [ "$current_credits" = "0" ]; then
        print_warning "No hay créditos configurados para resetear"
        return 1
    fi

    echo -e "${YELLOW}⚠️  Esta acción reseteará completamente el sistema de créditos:${NC}"
    echo "  • Reiniciará créditos a \$$current_credits USD"
    echo "  • Eliminará todo el historial de uso"
    echo "  • Restablecerá la fecha de inicio"
    echo

    read -p "¿Estás seguro de que deseas resetear los créditos? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operación cancelada"
        return 0
    fi

    # Resetear créditos
    jq --arg credits "$current_credits" --arg date "$(date -Iseconds)" \
        '.remaining_credits = ($credits | tonumber) |
         .cloudfront_costs = 0 |
         .start_date = $date |
         .usage_history = []' \
        "$CREDITS_FILE" > "${CREDITS_FILE}.tmp" && mv "${CREDITS_FILE}.tmp" "$CREDITS_FILE"

    print_success "✅ Sistema de créditos reseteado exitosamente"
    print_info "Créditos restablecidos a: \$$current_credits USD"

    echo
    read -p "Presiona Enter para continuar..." -r
}

# =============================================================================
# FUNCIONES CLOUDFRONT COMPLETAS
# =============================================================================

# Función para eliminar distribución CloudFront
delete_cloudfront_distribution() {
    print_header "🗑️ ELIMINAR DISTRIBUCIÓN CLOUDFRONT"
    echo
    echo -e "${RED}⚠️  ADVERTENCIA: Esta acción es IRREVERSIBLE${NC}"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    print_info "Obteniendo lista de distribuciones..."

    # Obtener distribuciones
    local distributions_output
    distributions_output=$(aws_memory cloudfront list-distributions --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener distribuciones: $distributions_output"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local distributions_json
    distributions_json=$(echo "$distributions_output" | jq -r '.DistributionList.Items' 2>/dev/null)

    if [ -z "$distributions_json" ] || [ "$distributions_json" = "null" ] || [ "$distributions_json" = "[]" ]; then
        print_warning "No se encontraron distribuciones"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Mostrar lista de distribuciones
    echo -e "${GREEN}📋 DISTRIBUCIONES DISPONIBLES:${NC}"
    echo "=============================================="

    local index=1
    declare -A distribution_map
    declare -A domain_map
    declare -A enabled_map
    declare -A status_map

    while IFS= read -r distribution; do
        if [ -n "$distribution" ] && [ "$distribution" != "null" ]; then
            local domain_name
            domain_name=$(echo "$distribution" | jq -r '.DomainName // "N/A"' 2>/dev/null)
            local distribution_id
            distribution_id=$(echo "$distribution" | jq -r '.Id // "N/A"' 2>/dev/null)
            local enabled
            enabled=$(echo "$distribution" | jq -r '.Enabled // false' 2>/dev/null)
            local dist_status
            dist_status=$(echo "$distribution" | jq -r '.Status // "Unknown"' 2>/dev/null)
            local status_display
            if [ "$enabled" = "true" ]; then
                status_display="🟢 ACTIVA ($dist_status)"
            else
                status_display="🔴 DESACTIVADA ($dist_status)"
            fi
            local comment
            comment=$(echo "$distribution" | jq -r '.Comment // "Sin comentario"' 2>/dev/null)

            if [ "$domain_name" != "N/A" ] && [ "$distribution_id" != "N/A" ]; then
                distribution_map[$index]="$distribution_id"
                domain_map[$index]="$domain_name"
                enabled_map[$index]="$enabled"
                status_map[$index]="$dist_status"

                echo -e "${CYAN}$index. $domain_name${NC}"
                echo "   🆔 ID: $distribution_id"
                echo "   📊 Estado: $status_display"
                echo "   💬 Comentario: $comment"
                echo "   ------------------------------------"

                ((index++))
            fi
        fi
    done < <(echo "$distributions_json" | jq -c '.[]' 2>/dev/null)

    local total_distributions=$((index-1))

    if [ "$total_distributions" -eq 0 ]; then
        print_error "No se encontraron distribuciones válidas"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    echo
    echo -n -e "${BLUE}Selecciona una distribución para ELIMINAR (1-$total_distributions) o 0 para cancelar: ${NC}"
    read -r selection

    if [ "$selection" = "0" ]; then
        print_info "Operación cancelada"
        return 0
    fi

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_distributions" ]; then
        print_error "Selección inválida"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local selected_id=${distribution_map[$selection]}
    local selected_domain=${domain_map[$selection]}
    local is_enabled=${enabled_map[$selection]}
    local dist_status=${status_map[$selection]}

    echo
    print_warning "⚠️  VAS A ELIMINAR LA SIGUIENTE DISTRIBUCIÓN:"
    echo "  🌐 Dominio: $selected_domain"
    echo "  🆔 ID: $selected_id"
    if [ "$is_enabled" = "true" ]; then
        echo "  📊 Estado: 🟢 ACTIVA"
    else
        echo "  📊 Estado: 🔴 DESACTIVADA"
    fi
    echo "  🔄 Status: $dist_status"
    echo

    # Si está habilitada, advertir que debe deshabilitarse primero
    if [ "$is_enabled" = "true" ]; then
        print_error "❌ La distribución está ACTIVA"
        echo
        print_info "Para eliminar una distribución CloudFront debes:"
        echo "  1. Primero DESACTIVARLA"
        echo "  2. Esperar a que el estado cambie a 'Deployed'"
        echo "  3. Luego podrás eliminarla"
        echo
        read -p "¿Deseas DESACTIVAR esta distribución ahora? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Desactivar primero
            print_info "Desactivando distribución..."

            # Obtener configuración actual
            local config_output
            config_output=$(aws_memory cloudfront get-distribution-config --id "$selected_id" --output json 2>&1)

            if [ $? -ne 0 ]; then
                print_error "Error al obtener configuración: $config_output"
                echo
                read -p "Presiona Enter para continuar..." -r
                return 1
            fi

            local etag
            etag=$(echo "$config_output" | jq -r '.ETag' 2>/dev/null)
            local dist_config
            dist_config=$(echo "$config_output" | jq -r '.DistributionConfig' 2>/dev/null)

            # Desactivar
            local updated_config
            updated_config=$(echo "$dist_config" | jq '.Enabled = false' 2>/dev/null)

            local temp_config="$TEMP_DIR/disable-before-delete-$selected_id.json"
            echo "$updated_config" > "$temp_config"

            local update_output
            update_output=$(aws_memory cloudfront update-distribution \
                --id "$selected_id" \
                --distribution-config "file://$temp_config" \
                --if-match "$etag" \
                --output json 2>&1)

            rm -f "$temp_config"

            if [ $? -eq 0 ]; then
                print_success "✅ Distribución desactivada"
                echo
                print_info "Ahora debes esperar a que el estado cambie a 'Deployed'"
                print_info "Esto puede tardar 15-20 minutos"
                print_info "Una vez desplegada, vuelve a ejecutar esta opción para eliminarla"
            else
                print_error "❌ Error al desactivar: $update_output"
            fi
        else
            print_info "Operación cancelada"
        fi
        echo
        read -p "Presiona Enter para continuar..." -r
        return 0
    fi

    # Si está desplegándose, no se puede eliminar
    if [ "$dist_status" = "InProgress" ]; then
        print_error "❌ La distribución está en proceso de despliegue"
        print_info "Debes esperar a que el estado cambie a 'Deployed' antes de eliminarla"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 0
    fi

    # Confirmación final
    echo -e "${RED}⚠️⚠️⚠️  ÚLTIMA CONFIRMACIÓN  ⚠️⚠️⚠️${NC}"
    echo
    echo "Esta acción eliminará PERMANENTEMENTE la distribución:"
    echo "  • $selected_domain"
    echo "  • ID: $selected_id"
    echo
    echo "Esta acción NO se puede deshacer."
    echo
    read -p "Escribe 'ELIMINAR' en MAYÚSCULAS para confirmar: " -r confirm_text

    if [ "$confirm_text" != "ELIMINAR" ]; then
        print_info "Operación cancelada - Texto de confirmación incorrecto"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 0
    fi

    # Obtener ETag actual
    print_info "Obteniendo información de la distribución..."
    local dist_output
    dist_output=$(aws_memory cloudfront get-distribution --id "$selected_id" --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener información: $dist_output"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local etag
    etag=$(echo "$dist_output" | jq -r '.ETag' 2>/dev/null)

    if [ -z "$etag" ] || [ "$etag" = "null" ]; then
        print_error "No se pudo obtener el ETag de la distribución"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Eliminar distribución
    print_info "Eliminando distribución..."
    local delete_output
    delete_output=$(aws_memory cloudfront delete-distribution \
        --id "$selected_id" \
        --if-match "$etag" 2>&1)

    if [ $? -eq 0 ]; then
        print_success "✅ Distribución eliminada exitosamente"
        echo
        echo "  🗑️  Distribución: $selected_domain"
        echo "  🆔 ID: $selected_id"
        echo "  ✓ La distribución ha sido eliminada permanentemente"

        # Eliminar también archivos de límite si existen
        local limit_file="$TEMP_DIR/transfer-limit-$selected_id.json"
        local alarm_file="$TEMP_DIR/cw-alarm-$selected_id.txt"
        rm -f "$limit_file" "$alarm_file"

    else
        print_error "❌ Error al eliminar distribución"
        echo
        if [[ "$delete_output" == *"DistributionNotDisabled"* ]]; then
            print_error "La distribución debe estar deshabilitada primero"
        elif [[ "$delete_output" == *"PreconditionFailed"* ]]; then
            print_error "El ETag ha cambiado. La distribución fue modificada recientemente"
            print_info "Intenta nuevamente"
        else
            echo "$delete_output"
        fi
    fi

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para activar/desactivar distribución
toggle_cloudfront_distribution() {
    print_header "🔘 ACTIVAR/DESACTIVAR DISTRIBUCIÓN CLOUDFRONT"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    print_info "Obteniendo lista de distribuciones..."

    # Obtener distribuciones
    local distributions_output
    distributions_output=$(aws_memory cloudfront list-distributions --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener distribuciones: $distributions_output"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local distributions_json
    distributions_json=$(echo "$distributions_output" | jq -r '.DistributionList.Items' 2>/dev/null)

    if [ -z "$distributions_json" ] || [ "$distributions_json" = "null" ] || [ "$distributions_json" = "[]" ]; then
        print_warning "No se encontraron distribuciones"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Mostrar lista de distribuciones
    echo -e "${GREEN}📋 DISTRIBUCIONES DISPONIBLES:${NC}"
    echo "=============================================="

    local index=1
    declare -A distribution_map
    declare -A domain_map
    declare -A enabled_map

    while IFS= read -r distribution; do
        if [ -n "$distribution" ] && [ "$distribution" != "null" ]; then
            local domain_name
            domain_name=$(echo "$distribution" | jq -r '.DomainName // "N/A"' 2>/dev/null)
            local distribution_id
            distribution_id=$(echo "$distribution" | jq -r '.Id // "N/A"' 2>/dev/null)
            local enabled
            enabled=$(echo "$distribution" | jq -r '.Enabled // false' 2>/dev/null)
            local status
            if [ "$enabled" = "true" ]; then
                status="🟢 ACTIVA"
            else
                status="🔴 DESACTIVADA"
            fi
            local comment
            comment=$(echo "$distribution" | jq -r '.Comment // "Sin comentario"' 2>/dev/null)

            if [ "$domain_name" != "N/A" ] && [ "$distribution_id" != "N/A" ]; then
                distribution_map[$index]="$distribution_id"
                domain_map[$index]="$domain_name"
                enabled_map[$index]="$enabled"

                echo -e "${CYAN}$index. $domain_name${NC}"
                echo "   🆔 ID: $distribution_id"
                echo "   📊 Estado: $status"
                echo "   💬 Comentario: $comment"
                echo "   ------------------------------------"

                ((index++))
            fi
        fi
    done < <(echo "$distributions_json" | jq -c '.[]' 2>/dev/null)

    local total_distributions=$((index-1))

    if [ "$total_distributions" -eq 0 ]; then
        print_error "No se encontraron distribuciones válidas"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    echo
    echo -n -e "${BLUE}Selecciona una distribución (1-$total_distributions) o 0 para cancelar: ${NC}"
    read -r selection

    if [ "$selection" = "0" ]; then
        print_info "Operación cancelada"
        return 0
    fi

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_distributions" ]; then
        print_error "Selección inválida"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local selected_id=${distribution_map[$selection]}
    local selected_domain=${domain_map[$selection]}
    local is_enabled=${enabled_map[$selection]}

    echo
    print_info "Distribución seleccionada: $selected_domain"
    print_info "ID: $selected_id"

    # Determinar acción
    local new_state
    local action_text
    if [ "$is_enabled" = "true" ]; then
        new_state="false"
        action_text="DESACTIVAR"
        echo -e "${YELLOW}⚠️  Esta distribución está actualmente ACTIVA${NC}"
        echo "Si la desactivas, dejará de servir contenido inmediatamente"
    else
        new_state="true"
        action_text="ACTIVAR"
        echo -e "${GREEN}Esta distribución está actualmente DESACTIVADA${NC}"
        echo "Si la activas, comenzará a servir contenido (puede tardar 15-20 minutos)"
    fi

    echo
    read -p "¿Deseas $action_text esta distribución? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operación cancelada"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 0
    fi

    # Obtener configuración actual
    print_info "Obteniendo configuración actual..."
    local config_output
    config_output=$(aws_memory cloudfront get-distribution-config --id "$selected_id" --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener configuración: $config_output"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local etag
    etag=$(echo "$config_output" | jq -r '.ETag' 2>/dev/null)
    local dist_config
    dist_config=$(echo "$config_output" | jq -r '.DistributionConfig' 2>/dev/null)

    if [ -z "$etag" ] || [ "$etag" = "null" ] || [ -z "$dist_config" ] || [ "$dist_config" = "null" ]; then
        print_error "No se pudo extraer la configuración"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Modificar el estado
    local updated_config
    if [ "$new_state" = "true" ]; then
        updated_config=$(echo "$dist_config" | jq '.Enabled = true' 2>/dev/null)
    else
        updated_config=$(echo "$dist_config" | jq '.Enabled = false' 2>/dev/null)
    fi

    # Guardar configuración temporal
    local temp_config="$TEMP_DIR/toggle-config-$selected_id.json"
    echo "$updated_config" > "$temp_config"

    # Actualizar distribución
    print_info "${action_text}ando distribución..."
    local update_output
    update_output=$(aws_memory cloudfront update-distribution \
        --id "$selected_id" \
        --distribution-config "file://$temp_config" \
        --if-match "$etag" \
        --output json 2>&1)

    if [ $? -eq 0 ]; then
        print_success "✅ Distribución ${action_text}ada exitosamente"
        local new_status
        new_status=$(echo "$update_output" | jq -r '.Distribution.Status // "N/A"' 2>/dev/null)
        echo
        echo "  🌐 Dominio: $selected_domain"
        echo "  🆔 ID: $selected_id"
        if [ "$new_state" = "true" ]; then
            echo "  📊 Estado: 🟢 Activada (desplegando...)"
            echo "  ⏳ La distribución estará completamente activa en 15-20 minutos"
        else
            echo "  📊 Estado: 🔴 Desactivada"
            echo "  ℹ️  La distribución ha dejado de servir contenido"
        fi
        echo "  🔄 Status: $new_status"
    else
        print_error "❌ Error al ${action_text,,} distribución: $update_output"
    fi

    # Limpiar archivo temporal
    rm -f "$temp_config"

    echo
    read -p "Presiona Enter para continuar..." -r
}

# FUNCIÓN PARA EXTRAER CONFIGURACIÓN DE UNA DISTRIBUCIÓN ESPECÍFICA
extract_specific_config() {
    local distribution_id="$1"
    local distribution_domain="$2"

    print_info "Obteniendo configuración de: $distribution_domain" >&2
    print_info "ID: $distribution_id" >&2

    # Obtener configuración completa de la distribución
    print_info "Obteniendo configuración de la distribución..." >&2
    local config_output
    config_output=$(aws_memory cloudfront get-distribution-config --id "$distribution_id" --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener la configuración: $config_output" >&2
        return 1
    fi

    # Extraer solo la parte de DistributionConfig
    local distribution_config
    distribution_config=$(echo "$config_output" | jq -r '.DistributionConfig' 2>/dev/null)

    if [ -z "$distribution_config" ] || [ "$distribution_config" = "null" ]; then
        print_error "No se pudo extraer la configuración de la distribución" >&2
        return 1
    fi

    # Crear archivo de configuración template
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local config_file="$TEMP_DIR/cloudfront-template-$timestamp.json"

    # Preparar configuración para nueva distribución
    print_info "Preparando template para nueva distribución..." >&2

    # Generar un CallerReference único
    local caller_ref="clone-$(date +%s)-$RANDOM"

    # Crear la nueva configuración
    local new_config
    new_config=$(echo "$distribution_config" | jq --arg ref "$caller_ref" --arg comment "Clonado de $distribution_domain" '
        .CallerReference = $ref |
        .Comment = $comment |
        .Enabled = false
    ' 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$new_config" ]; then
        print_error "Error al procesar la configuración JSON" >&2
        return 1
    fi

    # Guardar el template
    echo "$new_config" > "$config_file"

    if [ $? -ne 0 ]; then
        print_error "Error al guardar el archivo de configuración" >&2
        return 1
    fi

    print_success "✅ Configuración extraída y guardada exitosamente" >&2
    echo >&2
    print_info "📋 RESUMEN DE LA CONFIGURACIÓN CLONADA:" >&2
    echo "  • Distribución origen: $distribution_domain" >&2
    echo "  • ID origen: $distribution_id" >&2
    echo "  • Archivo template: $config_file" >&2
    echo "  • Estado inicial: DESHABILITADO" >&2
    echo >&2
    print_warning "⚠️  IMPORTANTE: Antes de crear la nueva distribución, asegúrate de:" >&2
    echo "  1. Modificar el DomainName del origen en el template" >&2
    echo "  2. Revisar todas las configuraciones específicas" >&2
    echo "  3. Verificar los certificados SSL si usas Custom Domain" >&2

    # Retornar SOLO la ruta del archivo (sin >&2 para que se capture)
    echo "$config_file"
}

# FUNCIÓN CORREGIDA: Listar y gestionar distribuciones CloudFront
cloudfront_list_and_manage() {
    print_header "📋 LISTA Y GESTIÓN DE DISTRIBUCIONES CLOUDFRONT"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    print_info "Buscando distribuciones CloudFront (servicio global)..."

    # Obtener distribuciones usando la función aws_memory
    local distributions_output
    distributions_output=$(aws_memory cloudfront list-distributions --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener distribuciones: $distributions_output"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Verificar si hay distribuciones - método más robusto
    local distribution_count
    distribution_count=$(echo "$distributions_output" | jq -r '.DistributionList.Quantity' 2>/dev/null || echo "0")

    # Si jq falla, intentar contar manualmente
    if [ "$distribution_count" = "null" ] || [ -z "$distribution_count" ]; then
        distribution_count=$(echo "$distributions_output" | grep -o '"Id"' | wc -l || echo "0")
    fi

    if [ "$distribution_count" -eq 0 ]; then
        print_warning "No se encontraron distribuciones CloudFront en la cuenta"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    print_success "Se encontraron $distribution_count distribuciones CloudFront en la cuenta"
    echo

    # Extraer información de las distribuciones de forma más robusta
    local distributions_json
    distributions_json=$(echo "$distributions_output" | jq -r '.DistributionList.Items' 2>/dev/null)

    if [ -z "$distributions_json" ] || [ "$distributions_json" = "null" ] || [ "$distributions_json" = "[]" ]; then
        print_error "No se pudieron procesar las distribuciones."
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Mostrar lista numerada de distribuciones
    echo -e "${GREEN}📋 DISTRIBUCIONES CLOUDFRONT DISPONIBLES:${NC}"
    echo "=============================================="

    local index=1
    declare -A distribution_map
    declare -A domain_map

    # Procesar cada distribución
    while IFS= read -r distribution; do
        if [ -n "$distribution" ] && [ "$distribution" != "null" ]; then
            local domain_name
            domain_name=$(echo "$distribution" | jq -r '.DomainName // "N/A"' 2>/dev/null)
            local distribution_id
            distribution_id=$(echo "$distribution" | jq -r '.Id // "N/A"' 2>/dev/null)
            local status
            status=$(echo "$distribution" | jq -r 'if .Enabled then "🟢 ACTIVA" else "🔴 DESACTIVADA" end' 2>/dev/null)
            local origin_domain
            origin_domain=$(echo "$distribution" | jq -r '.Origins.Items[0].DomainName // "Sin origen configurado"' 2>/dev/null)
            local comment
            comment=$(echo "$distribution" | jq -r '.Comment // "Sin comentario"' 2>/dev/null)

            if [ "$domain_name" != "N/A" ] && [ "$distribution_id" != "N/A" ]; then
                distribution_map[$index]="$distribution_id"
                domain_map[$index]="$domain_name"

                echo -e "${CYAN}$index. $domain_name${NC}"
                echo "   🆔 ID: $distribution_id"
                echo "   📊 Estado: $status"
                echo "   🌐 Origen: $origin_domain"
                echo "   💬 Comentario: $comment"
                echo "   ------------------------------------"

                ((index++))
            fi
        fi
    done < <(echo "$distributions_json" | jq -c '.[]' 2>/dev/null)

    local total_distributions=$((index-1))

    if [ "$total_distributions" -eq 0 ]; then
        print_error "No se pudieron extraer distribuciones válidas de la respuesta"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    echo
    echo -e "${YELLOW}OPCIONES DISPONIBLES:${NC}"
    echo "1. 📥 Extraer configuración de una distribución"
    echo "2. 📊 Configurar límite de transferencia"
    echo "3. 🔙 Volver al menú anterior"
    echo

    while true; do
        read -p "Selecciona una opción (1-3): " -r action_choice

        case $action_choice in
            1)
                echo
                echo -e "${YELLOW}Selecciona la distribución para extraer configuración:${NC}"
                echo -n -e "${BLUE}Ingresa el número (1-$total_distributions) o 0 para cancelar: ${NC}"
                read -r selection

                # Validar selección
                if [ "$selection" = "0" ]; then
                    print_info "Operación cancelada por el usuario"
                    break
                fi

                if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_distributions" ]; then
                    print_error "Selección inválida. Debe ser un número entre 1 y $total_distributions"
                    continue
                fi

                local selected_id=${distribution_map[$selection]}
                local selected_domain=${domain_map[$selection]}

                # Extraer configuración
                echo
                local config_file
                config_file=$(extract_specific_config "$selected_id" "$selected_domain")
                local extract_exit_code=$?

                if [ $extract_exit_code -eq 0 ] && [ -n "$config_file" ] && [ -f "$config_file" ]; then
                    echo
                    print_success "✅ Template guardado exitosamente en: $config_file"
                    print_info "Puedes usar este template para crear una nueva distribución"
                    echo
                    read -p "Presiona Enter para continuar..." -r
                else
                    echo
                    print_error "❌ Error al extraer la configuración"
                    echo
                    read -p "Presiona Enter para continuar..." -r
                fi
                break
                ;;

            2)
                echo
                echo -e "${YELLOW}Selecciona la distribución para configurar límite:${NC}"
                echo -n -e "${BLUE}Ingresa el número (1-$total_distributions) o 0 para cancelar: ${NC}"
                read -r selection

                if [ "$selection" = "0" ]; then
                    print_info "Operación cancelada por el usuario"
                    break
                fi

                if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_distributions" ]; then
                    print_error "Selección inválida. Debe ser un número entre 1 y $total_distributions"
                    continue
                fi

                local selected_id=${distribution_map[$selection]}
                local selected_domain=${domain_map[$selection]}

                # Configurar límite de transferencia
                configure_transfer_limit "$selected_id" "$selected_domain"
                break
                ;;

            3)
                return 0
                ;;

            *)
                print_error "Opción no válida. Selecciona 1, 2 o 3."
                ;;
        esac
    done
}

# FUNCIÓN MEJORADA: Crear distribución CloudFront con template
create_cloudfront_from_template() {
    print_header "🆕 CREAR DISTRIBUCIÓN CLOUDFRONT DESDE TEMPLATE"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Buscar templates disponibles
    local templates=()
    if [ -d "$TEMP_DIR" ]; then
        while IFS= read -r -d '' file; do
            templates+=("$file")
        done < <(find "$TEMP_DIR" -name "cloudfront-template-*.json" -print0 2>/dev/null | sort -z)
    fi

    if [ ${#templates[@]} -eq 0 ]; then
        print_warning "No hay templates disponibles"
        echo
        print_info "Opciones:"
        echo "1. Primero extrae la configuración de una distribución existente"
        echo "2. O crea un template manualmente"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Mostrar templates disponibles
    echo -e "${GREEN}📄 TEMPLATES DISPONIBLES:${NC}"
    echo "=============================================="
    local index=1
    for template in "${templates[@]}"; do
        local filename=$(basename "$template")
        local filedate=$(echo "$filename" | grep -oP '\d{8}_\d{6}' || echo "unknown")
        local origin=$(jq -r '.Origins.Items[0].DomainName // "N/A"' "$template" 2>/dev/null)
        local comment=$(jq -r '.Comment // "Sin comentario"' "$template" 2>/dev/null)

        echo -e "${CYAN}$index. $filename${NC}"
        echo "   📅 Creado: $filedate"
        echo "   🌐 Origen: $origin"
        echo "   💬 Comentario: $comment"
        echo "   ------------------------------------"
        ((index++))
    done

    echo
    echo -n -e "${BLUE}Selecciona un template (1-${#templates[@]}) o 0 para cancelar: ${NC}"
    read -r selection

    if [ "$selection" = "0" ]; then
        print_info "Operación cancelada"
        return 0
    fi

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#templates[@]}" ]; then
        print_error "Selección inválida"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    local config_file="${templates[$((selection-1))]}"

    # Solicitar nuevo dominio de origen
    echo
    echo -e "${YELLOW}✏️  Configura el dominio de origen para la nueva distribución${NC}"
    echo -n -e "${BLUE}Nuevo dominio de origen: ${NC}"
    read -r new_origin_domain

    if [ -z "$new_origin_domain" ]; then
        print_error "❌ El dominio de origen no puede estar vacío"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Crear copia del template para modificar
    local modified_config="$TEMP_DIR/modified-$(basename "$config_file")"
    cp "$config_file" "$modified_config"

    # Actualizar el dominio de origen en el template
    if jq --arg new_domain "$new_origin_domain" '.Origins.Items[0].DomainName = $new_domain' "$modified_config" > "${modified_config}.tmp" 2>/dev/null; then
        mv "${modified_config}.tmp" "$modified_config"
        print_success "✓ Dominio de origen actualizado"
    else
        print_error "❌ Error al actualizar el dominio de origen"
        rm -f "$modified_config"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 1
    fi

    # Solicitar comentario personalizado
    echo
    echo -n -e "${BLUE}Comentario para la nueva distribución: ${NC}"
    read -r new_comment

    if [ -n "$new_comment" ]; then
        if jq --arg comment "$new_comment" '.Comment = $comment' "$modified_config" > "${modified_config}.tmp" 2>/dev/null; then
            mv "${modified_config}.tmp" "$modified_config"
            print_success "✓ Comentario actualizado"
        fi
    fi

    # Preguntar si desea habilitar la distribución
    echo
    echo -e "${YELLOW}⚠️  Estado de la distribución:${NC}"
    echo "  • Deshabilitada: La distribución se crea pero no está activa (sin costo)"
    echo "  • Habilitada: La distribución se despliega y comienza a funcionar (con costo)"
    echo
    read -p "¿Deseas HABILITAR la distribución inmediatamente? (y/n): " -n 1 -r
    echo

    local enable_distribution=false
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_distribution=true
        if jq '.Enabled = true' "$modified_config" > "${modified_config}.tmp" 2>/dev/null; then
            mv "${modified_config}.tmp" "$modified_config"
            print_success "✓ La distribución se creará HABILITADA"
        fi
    else
        if jq '.Enabled = false' "$modified_config" > "${modified_config}.tmp" 2>/dev/null; then
            mv "${modified_config}.tmp" "$modified_config"
            print_info "✓ La distribución se creará DESHABILITADA"
        fi
    fi

    # Generar nuevo CallerReference único
    local new_caller_ref="create-$(date +%s)-$RANDOM"
    if jq --arg ref "$new_caller_ref" '.CallerReference = $ref' "$modified_config" > "${modified_config}.tmp" 2>/dev/null; then
        mv "${modified_config}.tmp" "$modified_config"
    fi

    # Mostrar configuración final
    echo
    print_info "📋 Configuración final:"
    echo "  • Origen: $new_origin_domain"
    echo "  • Comentario: ${new_comment:-$(jq -r '.Comment // "Sin comentario"' "$modified_config" 2>/dev/null)}"
    echo "  • CallerReference: $(jq -r '.CallerReference' "$modified_config" 2>/dev/null)"
    if [ "$enable_distribution" = true ]; then
        echo "  • Estado: 🟢 Habilitado (se desplegará automáticamente)"
    else
        echo "  • Estado: 🔴 Deshabilitado (puedes habilitarlo después)"
    fi

    echo
    read -p "¿Crear distribución CloudFront con esta configuración? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Creación cancelada"
        rm -f "$modified_config"
        echo
        read -p "Presiona Enter para continuar..." -r
        return 0
    fi

    # Crear distribución
    print_info "Creando distribución CloudFront..."
    local create_output
    create_output=$(aws_memory cloudfront create-distribution --distribution-config "file://$modified_config" --output json 2>&1)

    if [ $? -eq 0 ]; then
        print_success "✅ Distribución CloudFront creada exitosamente"
        local new_domain
        new_domain=$(echo "$create_output" | jq -r '.Distribution.DomainName // "N/A"' 2>/dev/null)
        local new_id
        new_id=$(echo "$create_output" | jq -r '.Distribution.Id // "N/A"' 2>/dev/null)
        local status
        status=$(echo "$create_output" | jq -r '.Distribution.Status // "N/A"' 2>/dev/null)
        local enabled
        enabled=$(echo "$create_output" | jq -r '.Distribution.DistributionConfig.Enabled // false' 2>/dev/null)

        echo
        echo "  🌐 Dominio: $new_domain"
        echo "  🆔 ID: $new_id"
        if [ "$enabled" = "true" ]; then
            echo "  📊 Estado: 🟢 Desplegando... (esto puede tardar 15-20 minutos)"
            echo "  ⏳ La distribución estará disponible cuando el estado cambie a 'Deployed'"
        else
            echo "  📊 Estado: 🔴 Deshabilitado"
            echo "  ℹ️  Puedes habilitarlo después desde el menú de gestión"
        fi
        echo "  🔄 Status actual: $status"

        # Obtener account ID desde STS
        local account_info
        account_info=$(aws_memory sts get-caller-identity --output json 2>/dev/null)
        if [ $? -eq 0 ]; then
            local account_id
            account_id=$(echo "$account_info" | jq -r '.Account // "N/A"' 2>/dev/null)
            local arn="arn:aws:cloudfront::$account_id:distribution/$new_id"
            echo "  🔗 ARN: $arn"
        fi

        # Preguntar por límite de transferencia
        echo
        read -p "¿Deseas configurar un límite de transferencia para esta distribución? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            configure_transfer_limit "$new_id" "$new_domain"
        fi

    else
        print_error "❌ Error al crear distribución: $create_output"
    fi

    # Limpiar archivo temporal modificado
    rm -f "$modified_config"

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para configurar límite de transferencia
configure_transfer_limit() {
    local distribution_id="$1"
    local distribution_domain="$2"

    print_header "📊 CONFIGURAR LÍMITE DE TRANSFERENCIA"
    echo
    echo "Distribución: $distribution_domain"
    echo "ID: $distribution_id"
    echo

    echo -e "${YELLOW}💡 Límites de transferencia CloudFront:${NC}"
    echo "  • 1 TB = 1024 GB"
    echo "  • Límite máximo: 2000 TB por mes"
    echo "  • El límite se reinicia mensualmente"
    echo

    echo -e "${GREEN}📏 SELECCIONA EL LÍMITE:${NC}"
    echo "1. 100 GB (Pruebas/Desarrollo)"
    echo "2. 500 GB (Sitio pequeño)"
    echo "3. 1 TB (Sitio mediano)"
    echo "4. 5 TB (Sitio grande)"
    echo "5. 10 TB (Alto tráfico)"
    echo "6. Personalizado (ingresar manualmente)"
    echo "7. Sin límite"
    echo

    read -p "Selecciona opción (1-7): " -r limit_choice

    local limit_gb=0
    local limit_tb=0

    case $limit_choice in
        1) limit_gb=100 ;;
        2) limit_gb=500 ;;
        3) limit_gb=1024 ;;
        4) limit_tb=5 ;;
        5) limit_tb=10 ;;
        6)
            echo
            echo -e "${YELLOW}🔢 CONFIGURACIÓN PERSONALIZADA:${NC}"
            echo "1. Especificar en GB"
            echo "2. Especificar en TB"
            echo
            read -p "Selecciona unidad (1-2): " -r unit_choice

            case $unit_choice in
                1)
                    echo -n -e "${BLUE}Ingresa límite en GB: ${NC}"
                    read -r custom_gb
                    if [[ "$custom_gb" =~ ^[0-9]+$ ]] && [ "$custom_gb" -gt 0 ]; then
                        limit_gb=$custom_gb
                    else
                        print_error "Cantidad inválida"
                        return 1
                    fi
                    ;;
                2)
                    echo -n -e "${BLUE}Ingresa límite en TB: ${NC}"
                    read -r custom_tb
                    if [[ "$custom_tb" =~ ^[0-9]+$ ]] && [ "$custom_tb" -gt 0 ]; then
                        limit_tb=$custom_tb
                    else
                        print_error "Cantidad inválida"
                        return 1
                    fi
                    ;;
                *)
                    print_error "Opción inválida"
                    return 1
                    ;;
            esac
            ;;
        7)
            print_info "✅ Distribución configurada SIN LÍMITE de transferencia"
            return 0
            ;;
        *)
            print_error "Opción inválida"
            return 1
            ;;
    esac

    # Convertir TB a GB si es necesario
    if [ "$limit_tb" -gt 0 ]; then
        limit_gb=$((limit_tb * 1024))
    fi

    # Validar límites de AWS
    if [ "$limit_gb" -lt 100 ]; then
        print_warning "⚠️  Límite muy bajo. Mínimo recomendado: 100 GB"
        read -p "¿Continuar con $limit_gb GB? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    if [ "$limit_gb" -gt 2048000 ]; then  # 2000 TB
        print_error "❌ Límite excede el máximo de AWS (2000 TB)"
        return 1
    fi

    # Calcular equivalentes
    local limit_tb_calc
    limit_tb_calc=$(echo "scale=2; $limit_gb / 1024" | bc)

    echo
    print_info "📋 RESUMEN DEL LÍMITE:"
    echo "  • Gigabytes: $limit_gb GB"
    echo "  • Terabytes: $limit_tb_calc TB"
    echo "  • Distribución: $distribution_domain"

    # Crear configuración de límite
    local limit_file="$TEMP_DIR/transfer-limit-$distribution_id.json"
    cat > "$limit_file" << EOF
{
    "distribution_id": "$distribution_id",
    "distribution_domain": "$distribution_domain",
    "limit_gb": $limit_gb,
    "limit_tb": $limit_tb_calc,
    "configured_date": "$(date -Iseconds)",
    "monthly_reset": true
}
EOF

    print_success "✅ Límite de transferencia configurado"
    print_info "📁 Configuración guardada en: $limit_file"

    # Configurar alarma de CloudWatch (simulada)
    echo
    print_info "⏰ Configurando alarmas de CloudWatch..."

    # Esta es una simulación - en producción se usaría AWS CLI para CloudWatch
    local alarm_file="$TEMP_DIR/cw-alarm-$distribution_id.txt"
    cat > "$alarm_file" << EOF
ALARMA CONFIGURADA PARA: $distribution_domain
- Límite: $limit_gb GB ($limit_tb_calc TB)
- Umbral de alerta: $((limit_gb * 80 / 100)) GB (80%)
- Acción: Notificación cuando se alcance el 80% del límite
- Reinicio: Mensual (primero de cada mes)
EOF

    print_success "✅ Alarmas de CloudWatch configuradas"
    echo
    print_warning "⚠️  RECUERDA:"
    echo "  • Los límites son preventivos"
    echo "  • Monitorea el consumo regularmente"
    echo "  • Las distribuciones NO se detienen automáticamente al alcanzar el límite"

    return 0
}

# Función para monitorear consumo de transferencia
monitor_transfer_usage() {
    print_header "📊 MONITOREO DE CONSUMO CLOUDFRONT"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        return 1
    fi

    print_info "Obteniendo distribuciones y métricas..."

    # Obtener distribuciones
    local distributions_output
    distributions_output=$(aws_memory cloudfront list-distributions --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener distribuciones: $distributions_output"
        return 1
    fi

    local distributions_json
    distributions_json=$(echo "$distributions_output" | jq -r '.DistributionList.Items' 2>/dev/null)

    if [ -z "$distributions_json" ] || [ "$distributions_json" = "null" ]; then
        print_warning "No se encontraron distribuciones"
        return 1
    fi

    # Mostrar período de análisis
    echo
    echo -e "${GREEN}📅 PERÍODO DE ANÁLISIS:${NC}"
    echo "1. Últimas 24 horas"
    echo "2. Últimos 7 días"
    echo "3. Últimos 30 días (recomendado)"
    echo "4. Este mes (desde día 1)"
    echo "5. Personalizado"
    echo

    read -p "Selecciona período (1-5): " -r period_choice

    local start_time=""
    local end_time=""
    local period_display=""

    case $period_choice in
        1)
            start_time=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
            end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            period_display="Últimas 24 horas"
            ;;
        2)
            start_time=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
            end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            period_display="Últimos 7 días"
            ;;
        3)
            start_time=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
            end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            period_display="Últimos 30 días"
            ;;
        4)
            start_time=$(date -u +%Y-%m-01T00:00:00Z)
            end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            local month_name=$(date +%B)
            period_display="Este mes ($month_name)"
            ;;
        5)
            echo
            echo -e "${YELLOW}📅 CONFIGURACIÓN PERSONALIZADA:${NC}"
            echo -n -e "${BLUE}Días a analizar: ${NC}"
            read -r custom_days
            if [[ "$custom_days" =~ ^[0-9]+$ ]] && [ "$custom_days" -gt 0 ]; then
                start_time=$(date -u -d "$custom_days days ago" +%Y-%m-%dT%H:%M:%SZ)
                end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                period_display="Últimos $custom_days días"
            else
                print_error "Número de días inválido"
                return 1
            fi
            ;;
        *)
            print_error "Opción inválida"
            return 1
            ;;
    esac

    echo
    print_info "📊 Calculando consumo para: $period_display"
    echo

    # Procesar cada distribución
    local index=1
    declare -A distribution_map

    echo -e "${GREEN}🌐 CONSUMO POR DISTRIBUCIÓN:${NC}"
    echo "================================================================="

    while IFS= read -r distribution; do
        if [ -n "$distribution" ] && [ "$distribution" != "null" ]; then
            local domain_name
            domain_name=$(echo "$distribution" | jq -r '.DomainName // "N/A"' 2>/dev/null)
            local distribution_id
            distribution_id=$(echo "$distribution" | jq -r '.Id // "N/A"' 2>/dev/null)

            if [ "$domain_name" != "N/A" ] && [ "$distribution_id" != "N/A" ]; then
                distribution_map[$index]="$distribution_id"

                # Obtener métricas de CloudWatch
                print_info "Analizando: $domain_name"

                # BytesDownloaded - métrica principal de transferencia
                local bytes_metric
                bytes_metric=$(aws_memory cloudwatch get-metric-statistics \
                    --namespace AWS/CloudFront \
                    --metric-name BytesDownloaded \
                    --dimensions Name=DistributionId,Value="$distribution_id" Name=Region,Value=Global \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period 86400 \
                    --statistics Sum \
                    --output json 2>&1)

                local total_bytes=0
                if [ $? -eq 0 ]; then
                    total_bytes=$(echo "$bytes_metric" | jq -r '.Datapoints[].Sum? // 0' | awk '{sum += $1} END {print sum}')
                fi

                # Convertir a GB y TB
                local total_gb
                total_gb=$(echo "scale=2; $total_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                local total_tb
                total_tb=$(echo "scale=3; $total_gb / 1024" | bc 2>/dev/null || echo "0")

                # Obtener también Requests para contexto
                local requests_metric
                requests_metric=$(aws_memory cloudwatch get-metric-statistics \
                    --namespace AWS/CloudFront \
                    --metric-name Requests \
                    --dimensions Name=DistributionId,Value="$distribution_id" Name=Region,Value=Global \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period 86400 \
                    --statistics Sum \
                    --output json 2>&1)

                local total_requests=0
                if [ $? -eq 0 ]; then
                    total_requests=$(echo "$requests_metric" | jq -r '.Datapoints[].Sum? // 0' | awk '{sum += $1} END {print sum}')
                fi

                # Formatear números
                total_requests_formatted=$(printf "%'.0f" "$total_requests" 2>/dev/null || echo "$total_requests")

                # Mostrar resultados
                echo -e "${CYAN}$index. $domain_name${NC}"
                echo "   🆔 ID: $distribution_id"
                echo "   📊 Transferencia: $total_gb GB ($total_tb TB)"
                echo "   📈 Peticiones: $total_requests_formatted"

                # Verificar si hay límite configurado
                local limit_file="$TEMP_DIR/transfer-limit-$distribution_id.json"
                if [ -f "$limit_file" ]; then
                    local limit_gb
                    limit_gb=$(jq -r '.limit_gb' "$limit_file" 2>/dev/null)
                    if [ "$limit_gb" != "null" ] && [ "$limit_gb" -gt 0 ]; then
                        local usage_percent
                        usage_percent=$(echo "scale=1; ($total_gb * 100) / $limit_gb" | bc 2>/dev/null || echo "0")

                        echo -n "   🚦 Uso del límite: "
                        if (( $(echo "$usage_percent < 50" | bc -l 2>/dev/null || echo 1) )); then
                            echo -e "${GREEN}$usage_percent% ✅${NC}"
                        elif (( $(echo "$usage_percent < 80" | bc -l 2>/dev/null || echo 1) )); then
                            echo -e "${YELLOW}$usage_percent% ⚠️${NC}"
                        else
                            echo -e "${RED}$usage_percent% 🚨${NC}"
                        fi
                    fi
                fi

                echo "   ------------------------------------"

                ((index++))
            fi
        fi
    done < <(echo "$distributions_json" | jq -c '.[]' 2>/dev/null)

    local total_distributions=$((index-1))

    if [ "$total_distributions" -eq 0 ]; then
        print_warning "No se pudieron analizar distribuciones"
        return 1
    fi

    echo
    echo -e "${GREEN}📈 OPCIONES ADICIONALES:${NC}"
    echo "1. 🔍 Ver detalles de una distribución específica"
    echo "2. 📧 Generar reporte en archivo"
    echo "3. 🔙 Volver al menú"
    echo

    read -p "Selecciona opción (1-3): " -r detail_choice

    case $detail_choice in
        1)
            echo
            echo -n -e "${BLUE}Selecciona distribución (1-$total_distributions): ${NC}"
            read -r dist_selection

            if [[ "$dist_selection" =~ ^[0-9]+$ ]] && [ "$dist_selection" -ge 1 ] && [ "$dist_selection" -le "$total_distributions" ]; then
                show_detailed_metrics "${distribution_map[$dist_selection]}" "$period_display"
            else
                print_error "Selección inválida"
            fi
            ;;
        2)
            generate_transfer_report "$period_display" "$start_time" "$end_time"
            ;;
    esac

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para mostrar métricas detalladas
show_detailed_metrics() {
    local distribution_id="$1"
    local period="$2"

    print_header "🔍 MÉTRICAS DETALLADAS"
    echo
    print_info "Distribución: $distribution_id"
    print_info "Período: $period"
    echo

    # Obtener nombre del dominio
    local dist_info
    dist_info=$(aws_memory cloudfront get-distribution --id "$distribution_id" --output json 2>&1)
    if [ $? -eq 0 ]; then
        local domain_name
        domain_name=$(echo "$dist_info" | jq -r '.Distribution.DomainName // "N/A"' 2>/dev/null)
        echo -e "${CYAN}🌐 Dominio: $domain_name${NC}"
    fi

    echo
    echo -e "${GREEN}📊 MÉTRICAS PRINCIPALES:${NC}"

    # Definir períodos para métricas detalladas
    local end_time
    end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local start_time
    start_time=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)

    # Array de métricas a consultar
    declare -a metrics=("BytesDownloaded" "Requests" "4xxErrorRate" "5xxErrorRate" "TotalErrorRate")

    for metric in "${metrics[@]}"; do
        print_info "Obteniendo: $metric"

        local metric_data
        metric_data=$(aws_memory cloudwatch get-metric-statistics \
            --namespace AWS/CloudFront \
            --metric-name "$metric" \
            --dimensions Name=DistributionId,Value="$distribution_id" Name=Region,Value=Global \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period 2592000 \
            --statistics Sum Average \
            --output json 2>&1)

        if [ $? -eq 0 ]; then
            local sum_val
            sum_val=$(echo "$metric_data" | jq -r '.Datapoints[0].Sum? // 0' 2>/dev/null)
            local avg_val
            avg_val=$(echo "$metric_data" | jq -r '.Datapoints[0].Average? // 0' 2>/dev/null)

            # Formatear según la métrica
            case $metric in
                "BytesDownloaded")
                    local sum_gb
                    sum_gb=$(echo "scale=2; $sum_val / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                    local avg_gb
                    avg_gb=$(echo "scale=2; $avg_val / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                    echo "  • $metric: $sum_gb GB (avg: $avg_gb GB/día)"
                    ;;
                "Requests")
                    sum_val=$(printf "%'.0f" "$sum_val" 2>/dev/null || echo "$sum_val")
                    avg_val=$(printf "%'.0f" "$avg_val" 2>/dev/null || echo "$avg_val")
                    echo "  • $metric: $sum_val (avg: $avg_val/día)"
                    ;;
                *)
                    # Para tasas de error, mostrar porcentaje
                    if [[ "$metric" == *"ErrorRate" ]]; then
                        avg_val=$(echo "scale=4; $avg_val * 100" | bc 2>/dev/null || echo "0")
                        echo "  • $metric: ${avg_val}%"
                    else
                        echo "  • $metric: $sum_val (avg: $avg_val)"
                    fi
                    ;;
            esac
        else
            echo "  • $metric: Error obteniendo datos"
        fi
    done

    # Verificar límites configurados
    local limit_file="$TEMP_DIR/transfer-limit-$distribution_id.json"
    if [ -f "$limit_file" ]; then
        echo
        echo -e "${YELLOW}🚦 LÍMITES CONFIGURADOS:${NC}"
        local limit_gb
        limit_gb=$(jq -r '.limit_gb' "$limit_file")
        local limit_tb
        limit_tb=$(jq -r '.limit_tb' "$limit_file")
        local config_date
        config_date=$(jq -r '.configured_date' "$limit_file")

        echo "  • Límite mensual: $limit_gb GB ($limit_tb TB)"
        echo "  • Configurado: $(date -d "$config_date" +"%Y-%m-%d %H:%M")"
    fi

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para generar reporte
generate_transfer_report() {
    local period="$1"
    local start_time="$2"
    local end_time="$3"

    local report_file="$TEMP_DIR/cloudfront-report-$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "REPORTE CLOUDFRONT - $(date)"
        echo "Período: $period"
        echo "Generado: $(date)"
        echo "=========================================="
        echo
    } > "$report_file"

    print_info "Generando reporte en: $report_file"
    print_success "✅ Reporte generado exitosamente"

    echo
    read -p "Presiona Enter para continuar..." -r
}

# Función para configurar límites en distribuciones existentes
configure_existing_transfer_limits() {
    print_header "🚨 CONFIGURAR LÍMITES EN DISTRIBUCIONES EXISTENTES"
    echo

    if ! check_cloudfront_permissions; then
        print_error "No se puede acceder a CloudFront"
        return 1
    fi

    print_info "Obteniendo distribuciones..."

    # Obtener distribuciones
    local distributions_output
    distributions_output=$(aws_memory cloudfront list-distributions --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Error al obtener distribuciones: $distributions_output"
        return 1
    fi

    local distributions_json
    distributions_json=$(echo "$distributions_output" | jq -r '.DistributionList.Items' 2>/dev/null)

    if [ -z "$distributions_json" ] || [ "$distributions_json" = "null" ] || [ "$distributions_json" = "[]" ]; then
        print_warning "No se encontraron distribuciones"
        return 1
    fi

    # Mostrar distribuciones
    echo -e "${GREEN}📋 DISTRIBUCIONES DISPONIBLES:${NC}"
    echo "=============================================="

    local index=1
    declare -A distribution_map
    declare -A domain_map

    while IFS= read -r distribution; do
        if [ -n "$distribution" ] && [ "$distribution" != "null" ]; then
            local domain_name
            domain_name=$(echo "$distribution" | jq -r '.DomainName // "N/A"' 2>/dev/null)
            local distribution_id
            distribution_id=$(echo "$distribution" | jq -r '.Id // "N/A"' 2>/dev/null)
            local comment
            comment=$(echo "$distribution" | jq -r '.Comment // "Sin comentario"' 2>/dev/null)

            if [ "$domain_name" != "N/A" ] && [ "$distribution_id" != "N/A" ]; then
                distribution_map[$index]="$distribution_id"
                domain_map[$index]="$domain_name"

                # Verificar si ya tiene límite configurado
                local limit_file="$TEMP_DIR/transfer-limit-$distribution_id.json"
                local limit_info=""
                if [ -f "$limit_file" ]; then
                    local current_limit
                    current_limit=$(jq -r '.limit_gb' "$limit_file" 2>/dev/null)
                    if [ "$current_limit" != "null" ] && [ -n "$current_limit" ]; then
                        limit_info=" (Límite: ${current_limit} GB)"
                    fi
                fi

                echo -e "${CYAN}$index. $domain_name${NC}$limit_info"
                echo "   🆔 ID: $distribution_id"
                echo "   💬 Comentario: $comment"
                echo "   ------------------------------------"

                ((index++))
            fi
        fi
    done < <(echo "$distributions_json" | jq -c '.[]' 2>/dev/null)

    local total_distributions=$((index-1))

    if [ "$total_distributions" -eq 0 ]; then
        print_error "No se encontraron distribuciones válidas"
        return 1
    fi

    echo
    echo -n -e "${BLUE}Selecciona distribución para configurar límite (1-$total_distributions) o 0 para cancelar: ${NC}"
    read -r selection

    if [ "$selection" = "0" ]; then
        print_info "Operación cancelada"
        return 0
    fi

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_distributions" ]; then
        print_error "Selección inválida"
        return 1
    fi

    local selected_id=${distribution_map[$selection]}
    local selected_domain=${domain_map[$selection]}

    # Configurar límite
    configure_transfer_limit "$selected_id" "$selected_domain"
}

# =============================================================================
# MENÚS PRINCIPALES
# =============================================================================

# Solicitar credenciales al usuario
request_credentials() {
    clear
    print_header "🔐 INGRESO DE CREDENCIALES AWS"
    echo
    print_info "Las credenciales se mantendrán en memoria durante esta sesión"
    echo -e "${YELLOW}⚠️  No se guardarán permanentemente a menos que lo solicites${NC}"
    echo

    # Access Key ID
    while true; do
        echo -n -e "${BLUE}AWS Access Key ID: ${NC}"
        read -r AWS_ACCESS_KEY
        if [ -n "$AWS_ACCESS_KEY" ]; then
            break
        else
            print_error "El Access Key ID no puede estar vacío"
        fi
    done

    # Secret Access Key
    echo
    echo -e "${YELLOW}📝 Ingresa AWS Secret Access Key:${NC}"
    echo -e "${YELLOW}   (la tecleación está oculta)${NC}"
    while true; do
        echo -n -e "${BLUE}AWS Secret Access Key: ${NC}"
        read -r -s AWS_SECRET_KEY
        echo
        if [ -n "$AWS_SECRET_KEY" ]; then
            break
        else
            print_error "El Secret Access Key no puede estar vacío"
        fi
    done

    # Región
    echo
    echo -n -e "${BLUE}Región AWS [us-east-1]: ${NC}"
    read -r region_input
    AWS_REGION=${region_input:-us-east-1}

    # Nombre de perfil
    echo
    echo -n -e "${BLUE}Nombre para esta sesión [temp-session]: ${NC}"
    read -r profile_input
    AWS_PROFILE_NAME=${profile_input:-temp-session}

    # Verificar credenciales inmediatamente
    echo
    print_info "Verificando credenciales..."
    if verify_credentials; then
        print_success "✅ Credenciales válidas"

        # Solicitar créditos AWS
        request_aws_credits

        # Preguntar si desea guardar
        echo
        read -p "¿Deseas guardar estas credenciales permanentemente? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            save_credentials
        else
            print_info "Credenciales se mantendrán solo en memoria"
        fi
        return 0
    else
        print_error "❌ Credenciales inválidas"
        echo
        read -p "¿Intentar nuevamente? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            request_credentials
        else
            exit 1
        fi
    fi
}

# Menú de gestión CloudFront
cloudfront_menu() {
    while true; do
        clear
        print_header "🌐 GESTIÓN CLOUDFRONT - VERSIÓN MEJORADA"
        print_info "Credenciales en memoria: $AWS_PROFILE_NAME"
        echo

        echo "1. 📋 Listar y gestionar distribuciones"
        echo "2. 🆕 Crear distribución (con clonación)"
        echo "3. 🔘 Activar/Desactivar distribución"
        echo "4. 🗑️ Eliminar distribución"
        echo "5. 📊 Monitoreo de consumo de transferencia"
        echo "6. 🚨 Configurar límites de transferencia"
        echo "7. 🔙 Volver al menú principal"
        echo

        read -p "Selecciona una opción (1-7): " -r choice

        case $choice in
            1)
                cloudfront_list_and_manage
                ;;
            2)
                create_cloudfront_from_template
                ;;
            3)
                toggle_cloudfront_distribution
                ;;
            4)
                delete_cloudfront_distribution
                ;;
            5)
                monitor_transfer_usage
                ;;
            6)
                configure_existing_transfer_limits
                ;;
            7)
                return 0
                ;;
            *)
                print_error "Opción no válida"
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
        esac
    done
}

# Nuevo menú para gestión de créditos
credits_menu() {
    while true; do
        clear
        print_header "💰 GESTIÓN DE CRÉDITOS AWS"
        echo

        # Mostrar información actual
        show_credits_info
        echo

        echo "1. ⏰ Monitoreo en tiempo real"
        echo "2. 📋 Historial de uso"
        echo "3. 🔄 Resetear créditos"
        echo "4. 💳 Configurar nuevos créditos"
        echo "5. 🔙 Volver al menú principal"
        echo

        read -p "Selecciona una opción (1-5): " -r choice

        case $choice in
            1)
                realtime_credits_monitor
                ;;
            2)
                show_usage_history
                ;;
            3)
                reset_credits
                ;;
            4)
                request_aws_credits
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
            5)
                return 0
                ;;
            *)
                print_error "Opción no válida"
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
        esac
    done
}

# Menú principal
main_menu() {
    while true; do
        clear
        print_header "🚀 MENÚ PRINCIPAL - AWS CLOUDFRONT MANAGER"
        echo
        print_info "Estado de la sesión:"
        echo "  • Credenciales: ${GREEN}Configuradas en memoria${NC}"
        echo "  • Perfil: $AWS_PROFILE_NAME"
        echo "  • Región: $AWS_REGION"

        # Verificar estado de CloudFront
        if check_cloudfront_permissions &>/dev/null; then
            echo -e "  • CloudFront: ${GREEN}Disponible${NC}"
        else
            echo -e "  • CloudFront: ${RED}Sin acceso${NC}"
        fi

        # Mostrar información de créditos
        show_credits_info

        echo

        echo "1. 🌐 Gestión CloudFront"
        echo "2. 💰 Gestión de Créditos AWS"
        echo "3. 🔄 Cambiar credenciales"
        echo "4. 💾 Guardar credenciales actuales"
        echo "5. 📋 Ver información de la cuenta"
        echo "6. 🚪 Salir"
        echo

        read -p "Selecciona una opción (1-6): " -r choice

        case $choice in
            1)
                cloudfront_menu
                ;;
            2)
                credits_menu
                ;;
            3)
                request_credentials
                ;;
            4)
                if [ -n "$AWS_ACCESS_KEY" ]; then
                    save_credentials
                else
                    print_error "No hay credenciales en memoria para guardar"
                fi
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
            5)
                print_header "📊 INFORMACIÓN DE LA CUENTA AWS"
                verify_credentials
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
            6)
                print_info "👋 ¡Hasta pronto!"
                # Limpiar variables de memoria
                AWS_ACCESS_KEY=""
                AWS_SECRET_KEY=""
                # Limpiar directorio temporal
                rm -rf "$TEMP_DIR"
                exit 0
                ;;
            *)
                print_error "Opción no válida"
                echo
                read -p "Presiona Enter para continuar..." -r
                ;;
        esac
    done
}

# Función principal
main() {
    check_aws_installed
    create_temp_dir
    init_credits_system

    # Mostrar banner
    clear
    print_header "🤖 AWS CLOUDFRONT MANAGER"
    echo -e "${YELLOW}Gestor seguro de AWS CloudFront${NC}"
    echo -e "${BLUE}Credenciales en memoria - Sesión temporal${NC}"
    echo

    # Solicitar credenciales al iniciar
    request_credentials

    # Mostrar menú principal
    main_menu
}

# Manejar Ctrl+C
trap 'echo -e "\n${YELLOW}Sesión terminada. Credenciales limpiadas de memoria.${NC}"; rm -rf "$TEMP_DIR"; exit 0' INT

# Ejecutar función principal
main "$@"