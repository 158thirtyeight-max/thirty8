export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      audit_logs: {
        Row: {
          action: string
          actor_profile_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          request_id: string | null
        }
        Insert: {
          action: string
          actor_profile_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          request_id?: string | null
        }
        Update: {
          action?: string
          actor_profile_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          request_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_actor_profile_id_fkey"
            columns: ["actor_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      boarding_events: {
        Row: {
          booking_item_id: string
          id: string
          result: string
          scanned_at: string
          scanned_by: string | null
          trip_id: string
        }
        Insert: {
          booking_item_id: string
          id?: string
          result: string
          scanned_at?: string
          scanned_by?: string | null
          trip_id: string
        }
        Update: {
          booking_item_id?: string
          id?: string
          result?: string
          scanned_at?: string
          scanned_by?: string | null
          trip_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "boarding_events_booking_item_id_fkey"
            columns: ["booking_item_id"]
            isOneToOne: false
            referencedRelation: "booking_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "boarding_events_scanned_by_fkey"
            columns: ["scanned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "boarding_events_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
        ]
      }
      boarding_points: {
        Row: {
          address: string | null
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          route_id: string
          sequence_no: number
        }
        Insert: {
          address?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name: string
          route_id: string
          sequence_no: number
        }
        Update: {
          address?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name?: string
          route_id?: string
          sequence_no?: number
        }
        Relationships: [
          {
            foreignKeyName: "boarding_points_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
            referencedColumns: ["id"]
          },
        ]
      }
      booking_items: {
        Row: {
          boarding_point_id: string
          booking_id: string
          created_at: string
          dropping_point_id: string
          fare_cents: number
          id: string
          passenger_id: string | null
          status: Database["public"]["Enums"]["booking_status"]
          trip_id: string
          trip_seat_id: string
        }
        Insert: {
          boarding_point_id: string
          booking_id: string
          created_at?: string
          dropping_point_id: string
          fare_cents: number
          id?: string
          passenger_id?: string | null
          status?: Database["public"]["Enums"]["booking_status"]
          trip_id: string
          trip_seat_id: string
        }
        Update: {
          boarding_point_id?: string
          booking_id?: string
          created_at?: string
          dropping_point_id?: string
          fare_cents?: number
          id?: string
          passenger_id?: string | null
          status?: Database["public"]["Enums"]["booking_status"]
          trip_id?: string
          trip_seat_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "booking_items_boarding_point_id_fkey"
            columns: ["boarding_point_id"]
            isOneToOne: false
            referencedRelation: "boarding_points"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_items_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_items_dropping_point_id_fkey"
            columns: ["dropping_point_id"]
            isOneToOne: false
            referencedRelation: "dropping_points"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_items_passenger_id_fkey"
            columns: ["passenger_id"]
            isOneToOne: false
            referencedRelation: "passengers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_items_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_items_trip_seat_id_fkey"
            columns: ["trip_seat_id"]
            isOneToOne: false
            referencedRelation: "trip_seats"
            referencedColumns: ["id"]
          },
        ]
      }
      booking_status_history: {
        Row: {
          booking_id: string
          changed_by: string | null
          created_at: string
          from_status: Database["public"]["Enums"]["booking_status"] | null
          id: string
          note: string | null
          to_status: Database["public"]["Enums"]["booking_status"]
        }
        Insert: {
          booking_id: string
          changed_by?: string | null
          created_at?: string
          from_status?: Database["public"]["Enums"]["booking_status"] | null
          id?: string
          note?: string | null
          to_status: Database["public"]["Enums"]["booking_status"]
        }
        Update: {
          booking_id?: string
          changed_by?: string | null
          created_at?: string
          from_status?: Database["public"]["Enums"]["booking_status"] | null
          id?: string
          note?: string | null
          to_status?: Database["public"]["Enums"]["booking_status"]
        }
        Relationships: [
          {
            foreignKeyName: "booking_status_history_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "booking_status_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bookings: {
        Row: {
          booking_reference: string
          contact_email: string | null
          contact_phone: string | null
          coupon_code: string | null
          created_at: string
          currency_code: string
          customer_id: string
          id: string
          status: Database["public"]["Enums"]["booking_status"]
          total_fare_cents: number
          updated_at: string
        }
        Insert: {
          booking_reference: string
          contact_email?: string | null
          contact_phone?: string | null
          coupon_code?: string | null
          created_at?: string
          currency_code?: string
          customer_id: string
          id?: string
          status?: Database["public"]["Enums"]["booking_status"]
          total_fare_cents?: number
          updated_at?: string
        }
        Update: {
          booking_reference?: string
          contact_email?: string | null
          contact_phone?: string | null
          coupon_code?: string | null
          created_at?: string
          currency_code?: string
          customer_id?: string
          id?: string
          status?: Database["public"]["Enums"]["booking_status"]
          total_fare_cents?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bookings_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_layouts: {
        Row: {
          bus_id: string
          created_at: string
          deck_count: number
          id: string
          is_active: boolean
          layout_json: Json
          name: string
          version: number
        }
        Insert: {
          bus_id: string
          created_at?: string
          deck_count?: number
          id?: string
          is_active?: boolean
          layout_json?: Json
          name?: string
          version?: number
        }
        Update: {
          bus_id?: string
          created_at?: string
          deck_count?: number
          id?: string
          is_active?: boolean
          layout_json?: Json
          name?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "bus_layouts_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_routes: {
        Row: {
          active: boolean
          created_at: string
          destination_city_id: string
          distance_km: number | null
          id: string
          operator_id: string
          source_city_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          destination_city_id: string
          distance_km?: number | null
          id?: string
          operator_id: string
          source_city_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          destination_city_id?: string
          distance_km?: number | null
          id?: string
          operator_id?: string
          source_city_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bus_routes_destination_city_id_fkey"
            columns: ["destination_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_routes_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_routes_source_city_id_fkey"
            columns: ["source_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_services: {
        Row: {
          bus_id: string
          created_at: string
          default_arrival_offset_minutes: number
          default_departure_time: string
          id: string
          operator_id: string
          route_id: string
          service_code: string | null
          service_dest_city_id: string
          service_name: string
          service_source_city_id: string
          status: Database["public"]["Enums"]["bus_service_status"]
          updated_at: string
        }
        Insert: {
          bus_id: string
          created_at?: string
          default_arrival_offset_minutes: number
          default_departure_time: string
          id?: string
          operator_id: string
          route_id: string
          service_code?: string | null
          service_dest_city_id: string
          service_name: string
          service_source_city_id: string
          status?: Database["public"]["Enums"]["bus_service_status"]
          updated_at?: string
        }
        Update: {
          bus_id?: string
          created_at?: string
          default_arrival_offset_minutes?: number
          default_departure_time?: string
          id?: string
          operator_id?: string
          route_id?: string
          service_code?: string | null
          service_dest_city_id?: string
          service_name?: string
          service_source_city_id?: string
          status?: Database["public"]["Enums"]["bus_service_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bus_services_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_services_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_services_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_services_service_dest_city_id_fkey"
            columns: ["service_dest_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_services_service_source_city_id_fkey"
            columns: ["service_source_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_trip_events: {
        Row: {
          event_type: string
          id: string
          latitude: number
          longitude: number
          point_name: string | null
          point_type: string | null
          recorded_at: string
          trip_id: string
        }
        Insert: {
          event_type: string
          id?: string
          latitude: number
          longitude: number
          point_name?: string | null
          point_type?: string | null
          recorded_at?: string
          trip_id: string
        }
        Update: {
          event_type?: string
          id?: string
          latitude?: number
          longitude?: number
          point_name?: string | null
          point_type?: string | null
          recorded_at?: string
          trip_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bus_trip_events_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_trips: {
        Row: {
          arrival_at: string | null
          available_seats: number
          booking_close_at: string | null
          booking_open_at: string
          bus_id: string
          created_at: string
          currency_code: string
          current_latitude: number | null
          current_longitude: number | null
          departure_at: string
          id: string
          last_location_update: string | null
          live_tracking_enabled: boolean
          max_fare_cents: number | null
          min_fare_cents: number | null
          operator_id: string
          route_id: string
          service_id: string
          status: Database["public"]["Enums"]["bus_trip_status"]
          travel_date: string
          updated_at: string
        }
        Insert: {
          arrival_at?: string | null
          available_seats?: number
          booking_close_at?: string | null
          booking_open_at?: string
          bus_id: string
          created_at?: string
          currency_code?: string
          current_latitude?: number | null
          current_longitude?: number | null
          departure_at: string
          id?: string
          last_location_update?: string | null
          live_tracking_enabled?: boolean
          max_fare_cents?: number | null
          min_fare_cents?: number | null
          operator_id: string
          route_id: string
          service_id: string
          status?: Database["public"]["Enums"]["bus_trip_status"]
          travel_date: string
          updated_at?: string
        }
        Update: {
          arrival_at?: string | null
          available_seats?: number
          booking_close_at?: string | null
          booking_open_at?: string
          bus_id?: string
          created_at?: string
          currency_code?: string
          current_latitude?: number | null
          current_longitude?: number | null
          departure_at?: string
          id?: string
          last_location_update?: string | null
          live_tracking_enabled?: boolean
          max_fare_cents?: number | null
          min_fare_cents?: number | null
          operator_id?: string
          route_id?: string
          service_id?: string
          status?: Database["public"]["Enums"]["bus_trip_status"]
          travel_date?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bus_trips_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_trips_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_trips_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_trips_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "bus_services"
            referencedColumns: ["id"]
          },
        ]
      }
      buses: {
        Row: {
          amenities: string[]
          bus_type: string
          created_at: string
          id: string
          operator_id: string
          photo_urls: string[]
          registration_number: string
          status: Database["public"]["Enums"]["bus_status"]
          total_seats: number
          updated_at: string
        }
        Insert: {
          amenities?: string[]
          bus_type: string
          created_at?: string
          id?: string
          operator_id: string
          photo_urls?: string[]
          registration_number: string
          status?: Database["public"]["Enums"]["bus_status"]
          total_seats: number
          updated_at?: string
        }
        Update: {
          amenities?: string[]
          bus_type?: string
          created_at?: string
          id?: string
          operator_id?: string
          photo_urls?: string[]
          registration_number?: string
          status?: Database["public"]["Enums"]["bus_status"]
          total_seats?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "buses_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_hub: {
        Row: {
          address: string | null
          city_id: string
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          operating_hours: string | null
          operator_id: string | null
        }
        Insert: {
          address?: string | null
          city_id: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name: string
          operating_hours?: string | null
          operator_id?: string | null
        }
        Update: {
          address?: string | null
          city_id?: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name?: string
          operating_hours?: string | null
          operator_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "cargo_hub_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_hub_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_pricing_rules: {
        Row: {
          base_fare_cents: number
          cargo_type_id: string
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          per_kg_cents: number
          per_km_cents: number
          route_id: string
          surcharge_cents: number
          vehicle_type_id: string
        }
        Insert: {
          base_fare_cents: number
          cargo_type_id: string
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          per_kg_cents?: number
          per_km_cents?: number
          route_id: string
          surcharge_cents?: number
          vehicle_type_id: string
        }
        Update: {
          base_fare_cents?: number
          cargo_type_id?: string
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          per_kg_cents?: number
          per_km_cents?: number
          route_id?: string
          surcharge_cents?: number
          vehicle_type_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cargo_pricing_rules_cargo_type_id_fkey"
            columns: ["cargo_type_id"]
            isOneToOne: false
            referencedRelation: "cargo_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_pricing_rules_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "cargo_routes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_pricing_rules_vehicle_type_id_fkey"
            columns: ["vehicle_type_id"]
            isOneToOne: false
            referencedRelation: "cargo_vehicle_types"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_routes: {
        Row: {
          active: boolean
          created_at: string
          destination_city_id: string
          distance_km: number | null
          id: string
          operator_id: string
          source_city_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          destination_city_id: string
          distance_km?: number | null
          id?: string
          operator_id: string
          source_city_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          destination_city_id?: string
          distance_km?: number | null
          id?: string
          operator_id?: string
          source_city_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cargo_routes_destination_city_id_fkey"
            columns: ["destination_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_routes_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_routes_source_city_id_fkey"
            columns: ["source_city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_shipments: {
        Row: {
          actual_delivered_at: string | null
          base_fare_cents: number
          cargo_type_id: string
          created_at: string
          currency_code: string
          current_latitude: number | null
          current_longitude: number | null
          declared_value_cents: number | null
          delivery_address: string | null
          delivery_contact_name: string | null
          delivery_contact_phone: string | null
          delivery_hub_id: string | null
          delivery_latitude: number | null
          delivery_longitude: number | null
          delivery_proof_url: string | null
          delivery_scheduled_at: string | null
          delivery_type: Database["public"]["Enums"]["cargo_point_type"]
          description: string | null
          discount_cents: number
          distance_fare_cents: number
          estimated_delivery_at: string | null
          height_cm: number | null
          id: string
          last_location_update: string | null
          length_cm: number | null
          operator_id: string | null
          pickup_address: string | null
          pickup_contact_name: string | null
          pickup_contact_phone: string | null
          pickup_hub_id: string | null
          pickup_latitude: number | null
          pickup_longitude: number | null
          pickup_proof_url: string | null
          pickup_scheduled_at: string | null
          pickup_type: Database["public"]["Enums"]["cargo_point_type"]
          recipient_name: string | null
          route_id: string | null
          sender_user_id: string
          shipment_reference: string
          shipping_speed: Database["public"]["Enums"]["cargo_speed"]
          special_instructions: string | null
          status: Database["public"]["Enums"]["cargo_shipment_status"]
          surcharge_cents: number
          total_fare_cents: number
          updated_at: string
          vehicle_id: string | null
          volume_cbm: number | null
          weight_fare_cents: number
          weight_kg: number
          width_cm: number | null
        }
        Insert: {
          actual_delivered_at?: string | null
          base_fare_cents?: number
          cargo_type_id: string
          created_at?: string
          currency_code?: string
          current_latitude?: number | null
          current_longitude?: number | null
          declared_value_cents?: number | null
          delivery_address?: string | null
          delivery_contact_name?: string | null
          delivery_contact_phone?: string | null
          delivery_hub_id?: string | null
          delivery_latitude?: number | null
          delivery_longitude?: number | null
          delivery_proof_url?: string | null
          delivery_scheduled_at?: string | null
          delivery_type: Database["public"]["Enums"]["cargo_point_type"]
          description?: string | null
          discount_cents?: number
          distance_fare_cents?: number
          estimated_delivery_at?: string | null
          height_cm?: number | null
          id?: string
          last_location_update?: string | null
          length_cm?: number | null
          operator_id?: string | null
          pickup_address?: string | null
          pickup_contact_name?: string | null
          pickup_contact_phone?: string | null
          pickup_hub_id?: string | null
          pickup_latitude?: number | null
          pickup_longitude?: number | null
          pickup_proof_url?: string | null
          pickup_scheduled_at?: string | null
          pickup_type: Database["public"]["Enums"]["cargo_point_type"]
          recipient_name?: string | null
          route_id?: string | null
          sender_user_id: string
          shipment_reference: string
          shipping_speed?: Database["public"]["Enums"]["cargo_speed"]
          special_instructions?: string | null
          status?: Database["public"]["Enums"]["cargo_shipment_status"]
          surcharge_cents?: number
          total_fare_cents?: number
          updated_at?: string
          vehicle_id?: string | null
          volume_cbm?: number | null
          weight_fare_cents?: number
          weight_kg: number
          width_cm?: number | null
        }
        Update: {
          actual_delivered_at?: string | null
          base_fare_cents?: number
          cargo_type_id?: string
          created_at?: string
          currency_code?: string
          current_latitude?: number | null
          current_longitude?: number | null
          declared_value_cents?: number | null
          delivery_address?: string | null
          delivery_contact_name?: string | null
          delivery_contact_phone?: string | null
          delivery_hub_id?: string | null
          delivery_latitude?: number | null
          delivery_longitude?: number | null
          delivery_proof_url?: string | null
          delivery_scheduled_at?: string | null
          delivery_type?: Database["public"]["Enums"]["cargo_point_type"]
          description?: string | null
          discount_cents?: number
          distance_fare_cents?: number
          estimated_delivery_at?: string | null
          height_cm?: number | null
          id?: string
          last_location_update?: string | null
          length_cm?: number | null
          operator_id?: string | null
          pickup_address?: string | null
          pickup_contact_name?: string | null
          pickup_contact_phone?: string | null
          pickup_hub_id?: string | null
          pickup_latitude?: number | null
          pickup_longitude?: number | null
          pickup_proof_url?: string | null
          pickup_scheduled_at?: string | null
          pickup_type?: Database["public"]["Enums"]["cargo_point_type"]
          recipient_name?: string | null
          route_id?: string | null
          sender_user_id?: string
          shipment_reference?: string
          shipping_speed?: Database["public"]["Enums"]["cargo_speed"]
          special_instructions?: string | null
          status?: Database["public"]["Enums"]["cargo_shipment_status"]
          surcharge_cents?: number
          total_fare_cents?: number
          updated_at?: string
          vehicle_id?: string | null
          volume_cbm?: number | null
          weight_fare_cents?: number
          weight_kg?: number
          width_cm?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "cargo_shipments_cargo_type_id_fkey"
            columns: ["cargo_type_id"]
            isOneToOne: false
            referencedRelation: "cargo_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_delivery_hub_id_fkey"
            columns: ["delivery_hub_id"]
            isOneToOne: false
            referencedRelation: "cargo_hub"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_pickup_hub_id_fkey"
            columns: ["pickup_hub_id"]
            isOneToOne: false
            referencedRelation: "cargo_hub"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "cargo_routes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_sender_user_id_fkey"
            columns: ["sender_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_shipments_vehicle_id_fkey"
            columns: ["vehicle_id"]
            isOneToOne: false
            referencedRelation: "cargo_vehicles"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_status_history: {
        Row: {
          changed_by: string | null
          created_at: string
          from_status:
            | Database["public"]["Enums"]["cargo_shipment_status"]
            | null
          id: string
          note: string | null
          shipment_id: string
          to_status: Database["public"]["Enums"]["cargo_shipment_status"]
        }
        Insert: {
          changed_by?: string | null
          created_at?: string
          from_status?:
            | Database["public"]["Enums"]["cargo_shipment_status"]
            | null
          id?: string
          note?: string | null
          shipment_id: string
          to_status: Database["public"]["Enums"]["cargo_shipment_status"]
        }
        Update: {
          changed_by?: string | null
          created_at?: string
          from_status?:
            | Database["public"]["Enums"]["cargo_shipment_status"]
            | null
          id?: string
          note?: string | null
          shipment_id?: string
          to_status?: Database["public"]["Enums"]["cargo_shipment_status"]
        }
        Relationships: [
          {
            foreignKeyName: "cargo_status_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_status_history_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "cargo_shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_tracking_events: {
        Row: {
          created_at: string
          event_type: string
          id: string
          latitude: number
          longitude: number
          milestone_hub_id: string | null
          recorded_at: string
          shipment_id: string
        }
        Insert: {
          created_at?: string
          event_type: string
          id?: string
          latitude: number
          longitude: number
          milestone_hub_id?: string | null
          recorded_at?: string
          shipment_id: string
        }
        Update: {
          created_at?: string
          event_type?: string
          id?: string
          latitude?: number
          longitude?: number
          milestone_hub_id?: string | null
          recorded_at?: string
          shipment_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cargo_tracking_events_milestone_hub_id_fkey"
            columns: ["milestone_hub_id"]
            isOneToOne: false
            referencedRelation: "cargo_hub"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_tracking_events_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "cargo_shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      cargo_types: {
        Row: {
          created_at: string
          id: string
          max_weight_kg: number
          name: string
          requires_special_handling: boolean
        }
        Insert: {
          created_at?: string
          id?: string
          max_weight_kg: number
          name: string
          requires_special_handling?: boolean
        }
        Update: {
          created_at?: string
          id?: string
          max_weight_kg?: number
          name?: string
          requires_special_handling?: boolean
        }
        Relationships: []
      }
      cargo_vehicle_types: {
        Row: {
          created_at: string
          id: string
          max_volume_cbm: number
          max_weight_kg: number
          name: string
        }
        Insert: {
          created_at?: string
          id?: string
          max_volume_cbm: number
          max_weight_kg: number
          name: string
        }
        Update: {
          created_at?: string
          id?: string
          max_volume_cbm?: number
          max_weight_kg?: number
          name?: string
        }
        Relationships: []
      }
      cargo_vehicles: {
        Row: {
          created_at: string
          id: string
          operator_id: string
          photo_urls: string[]
          registration_number: string
          status: Database["public"]["Enums"]["bus_status"]
          updated_at: string
          vehicle_type_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          operator_id: string
          photo_urls?: string[]
          registration_number: string
          status?: Database["public"]["Enums"]["bus_status"]
          updated_at?: string
          vehicle_type_id: string
        }
        Update: {
          created_at?: string
          id?: string
          operator_id?: string
          photo_urls?: string[]
          registration_number?: string
          status?: Database["public"]["Enums"]["bus_status"]
          updated_at?: string
          vehicle_type_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cargo_vehicles_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cargo_vehicles_vehicle_type_id_fkey"
            columns: ["vehicle_type_id"]
            isOneToOne: false
            referencedRelation: "cargo_vehicle_types"
            referencedColumns: ["id"]
          },
        ]
      }
      cities: {
        Row: {
          country_id: string
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          state: string | null
        }
        Insert: {
          country_id: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name: string
          state?: string | null
        }
        Update: {
          country_id?: string
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name?: string
          state?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "cities_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
        ]
      }
      countries: {
        Row: {
          code: string
          created_at: string
          id: string
          name: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          name: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          name?: string
        }
        Relationships: []
      }
      device_tokens: {
        Row: {
          created_at: string
          fcm_token: string
          id: string
          platform: string
          profile_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          fcm_token: string
          id?: string
          platform: string
          profile_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          fcm_token?: string
          id?: string
          platform?: string
          profile_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_tokens_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      dropping_points: {
        Row: {
          address: string | null
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          route_id: string
          sequence_no: number
        }
        Insert: {
          address?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name: string
          route_id: string
          sequence_no: number
        }
        Update: {
          address?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          latitude?: number | null
          longitude?: number | null
          name?: string
          route_id?: string
          sequence_no?: number
        }
        Relationships: [
          {
            foreignKeyName: "dropping_points_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
            referencedColumns: ["id"]
          },
        ]
      }
      fare_rules: {
        Row: {
          base_fare_cents: number
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          seat_type: Database["public"]["Enums"]["seat_type"]
          service_id: string
        }
        Insert: {
          base_fare_cents: number
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          seat_type: Database["public"]["Enums"]["seat_type"]
          service_id: string
        }
        Update: {
          base_fare_cents?: number
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          seat_type?: Database["public"]["Enums"]["seat_type"]
          service_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fare_rules_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "bus_services"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_preferences: {
        Row: {
          email_enabled: boolean
          id: string
          profile_id: string
          push_enabled: boolean
          sms_enabled: boolean
          updated_at: string
        }
        Insert: {
          email_enabled?: boolean
          id?: string
          profile_id: string
          push_enabled?: boolean
          sms_enabled?: boolean
          updated_at?: string
        }
        Update: {
          email_enabled?: boolean
          id?: string
          profile_id?: string
          push_enabled?: boolean
          sms_enabled?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_preferences_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_templates: {
        Row: {
          body_template: string
          created_at: string
          key: string
          title_template: string
        }
        Insert: {
          body_template: string
          created_at?: string
          key: string
          title_template: string
        }
        Update: {
          body_template?: string
          created_at?: string
          key?: string
          title_template?: string
        }
        Relationships: []
      }
      notifications: {
        Row: {
          body: string | null
          created_at: string
          data: Json
          id: string
          is_read: boolean
          profile_id: string
          title: string
          type: string | null
        }
        Insert: {
          body?: string | null
          created_at?: string
          data?: Json
          id?: string
          is_read?: boolean
          profile_id: string
          title: string
          type?: string | null
        }
        Update: {
          body?: string | null
          created_at?: string
          data?: Json
          id?: string
          is_read?: boolean
          profile_id?: string
          title?: string
          type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "notifications_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_insurance: {
        Row: {
          bus_id: string | null
          cargo_vehicle_id: string | null
          coverage_type: string | null
          created_at: string
          document_url: string | null
          id: string
          insurance_provider: string
          operator_id: string
          policy_number: string
          rejection_reason: string | null
          status: string
          updated_at: string
          valid_from: string
          valid_until: string
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          bus_id?: string | null
          cargo_vehicle_id?: string | null
          coverage_type?: string | null
          created_at?: string
          document_url?: string | null
          id?: string
          insurance_provider: string
          operator_id: string
          policy_number: string
          rejection_reason?: string | null
          status?: string
          updated_at?: string
          valid_from: string
          valid_until: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          bus_id?: string | null
          cargo_vehicle_id?: string | null
          coverage_type?: string | null
          created_at?: string
          document_url?: string | null
          id?: string
          insurance_provider?: string
          operator_id?: string
          policy_number?: string
          rejection_reason?: string | null
          status?: string
          updated_at?: string
          valid_from?: string
          valid_until?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "operator_insurance_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operator_insurance_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      operators: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          rating: number | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          business_type?: Database["public"]["Enums"]["operator_business_type"]
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          legal_name?: string | null
          name: string
          rating?: number | null
          settlement_config?: Json
          status?: Database["public"]["Enums"]["operator_status"]
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          business_type?: Database["public"]["Enums"]["operator_business_type"]
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          legal_name?: string | null
          name?: string
          rating?: number | null
          settlement_config?: Json
          status?: Database["public"]["Enums"]["operator_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "operators_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      orders: {
        Row: {
          amount_cents: number
          created_at: string
          currency_code: string
          customer_id: string
          id: string
          order_reference: string
          orderable_id: string
          orderable_type: Database["public"]["Enums"]["orderable_type"]
          razorpay_order_id: string | null
          status: Database["public"]["Enums"]["order_status"]
          updated_at: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          currency_code?: string
          customer_id: string
          id?: string
          order_reference: string
          orderable_id: string
          orderable_type: Database["public"]["Enums"]["orderable_type"]
          razorpay_order_id?: string | null
          status?: Database["public"]["Enums"]["order_status"]
          updated_at?: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          currency_code?: string
          customer_id?: string
          id?: string
          order_reference?: string
          orderable_id?: string
          orderable_type?: Database["public"]["Enums"]["orderable_type"]
          razorpay_order_id?: string | null
          status?: Database["public"]["Enums"]["order_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      passengers: {
        Row: {
          age: number
          booking_id: string
          created_at: string
          full_name: string
          gender: Database["public"]["Enums"]["passenger_gender"]
          id: string
          phone: string | null
        }
        Insert: {
          age: number
          booking_id: string
          created_at?: string
          full_name: string
          gender: Database["public"]["Enums"]["passenger_gender"]
          id?: string
          phone?: string | null
        }
        Update: {
          age?: number
          booking_id?: string
          created_at?: string
          full_name?: string
          gender?: Database["public"]["Enums"]["passenger_gender"]
          id?: string
          phone?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "passengers_booking_id_fkey"
            columns: ["booking_id"]
            isOneToOne: false
            referencedRelation: "bookings"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount_cents: number
          captured_at: string | null
          created_at: string
          id: string
          method: string | null
          order_id: string
          raw_response: Json | null
          razorpay_payment_id: string | null
          status: Database["public"]["Enums"]["payment_status"]
        }
        Insert: {
          amount_cents: number
          captured_at?: string | null
          created_at?: string
          id?: string
          method?: string | null
          order_id: string
          raw_response?: Json | null
          razorpay_payment_id?: string | null
          status?: Database["public"]["Enums"]["payment_status"]
        }
        Update: {
          amount_cents?: number
          captured_at?: string | null
          created_at?: string
          id?: string
          method?: string | null
          order_id?: string
          raw_response?: Json | null
          razorpay_payment_id?: string | null
          status?: Database["public"]["Enums"]["payment_status"]
        }
        Relationships: [
          {
            foreignKeyName: "payments_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      processed_webhook_events: {
        Row: {
          event_id: string
          event_type: string | null
          id: string
          processed_at: string
        }
        Insert: {
          event_id: string
          event_type?: string | null
          id?: string
          processed_at?: string
        }
        Update: {
          event_id?: string
          event_type?: string | null
          id?: string
          processed_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          email: string | null
          full_name: string | null
          id: string
          phone: string | null
          preferred_language: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          full_name?: string | null
          id: string
          phone?: string | null
          preferred_language?: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          full_name?: string | null
          id?: string
          phone?: string | null
          preferred_language?: string
          updated_at?: string
        }
        Relationships: []
      }
      ratings_reviews: {
        Row: {
          created_at: string
          id: string
          operator_id: string | null
          profile_id: string
          rating: number
          review: string | null
          shipment_id: string | null
          trip_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          operator_id?: string | null
          profile_id: string
          rating: number
          review?: string | null
          shipment_id?: string | null
          trip_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          operator_id?: string | null
          profile_id?: string
          rating?: number
          review?: string | null
          shipment_id?: string | null
          trip_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ratings_reviews_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_reviews_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_reviews_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "cargo_shipments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ratings_reviews_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
        ]
      }
      refunds: {
        Row: {
          amount_cents: number
          created_at: string
          id: string
          payment_id: string
          processed_at: string | null
          razorpay_refund_id: string | null
          reason: string | null
          status: Database["public"]["Enums"]["refund_status"]
        }
        Insert: {
          amount_cents: number
          created_at?: string
          id?: string
          payment_id: string
          processed_at?: string | null
          razorpay_refund_id?: string | null
          reason?: string | null
          status?: Database["public"]["Enums"]["refund_status"]
        }
        Update: {
          amount_cents?: number
          created_at?: string
          id?: string
          payment_id?: string
          processed_at?: string | null
          razorpay_refund_id?: string | null
          reason?: string | null
          status?: Database["public"]["Enums"]["refund_status"]
        }
        Relationships: [
          {
            foreignKeyName: "refunds_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_passengers: {
        Row: {
          age: number
          created_at: string
          full_name: string
          gender: Database["public"]["Enums"]["passenger_gender"]
          id: string
          phone: string | null
          profile_id: string
        }
        Insert: {
          age: number
          created_at?: string
          full_name: string
          gender: Database["public"]["Enums"]["passenger_gender"]
          id?: string
          phone?: string | null
          profile_id: string
        }
        Update: {
          age?: number
          created_at?: string
          full_name?: string
          gender?: Database["public"]["Enums"]["passenger_gender"]
          id?: string
          phone?: string | null
          profile_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "saved_passengers_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      seat_holds: {
        Row: {
          created_at: string
          expires_at: string
          hold_token: string
          id: string
          status: Database["public"]["Enums"]["seat_hold_status"]
          trip_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          expires_at: string
          hold_token?: string
          id?: string
          status?: Database["public"]["Enums"]["seat_hold_status"]
          trip_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          expires_at?: string
          hold_token?: string
          id?: string
          status?: Database["public"]["Enums"]["seat_hold_status"]
          trip_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "seat_holds_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "seat_holds_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      seats: {
        Row: {
          bus_layout_id: string
          col_no: number | null
          created_at: string
          deck: number
          gender_restriction: Database["public"]["Enums"]["gender_restriction"]
          id: string
          row_no: number | null
          seat_code: string
          seat_type: Database["public"]["Enums"]["seat_type"]
        }
        Insert: {
          bus_layout_id: string
          col_no?: number | null
          created_at?: string
          deck?: number
          gender_restriction?: Database["public"]["Enums"]["gender_restriction"]
          id?: string
          row_no?: number | null
          seat_code: string
          seat_type?: Database["public"]["Enums"]["seat_type"]
        }
        Update: {
          bus_layout_id?: string
          col_no?: number | null
          created_at?: string
          deck?: number
          gender_restriction?: Database["public"]["Enums"]["gender_restriction"]
          id?: string
          row_no?: number | null
          seat_code?: string
          seat_type?: Database["public"]["Enums"]["seat_type"]
        }
        Relationships: [
          {
            foreignKeyName: "seats_bus_layout_id_fkey"
            columns: ["bus_layout_id"]
            isOneToOne: false
            referencedRelation: "bus_layouts"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_seats: {
        Row: {
          fare_cents: number
          hold_id: string | null
          id: string
          seat_id: string
          status: Database["public"]["Enums"]["trip_seat_status"]
          trip_id: string
          updated_at: string
        }
        Insert: {
          fare_cents?: number
          hold_id?: string | null
          id?: string
          seat_id: string
          status?: Database["public"]["Enums"]["trip_seat_status"]
          trip_id: string
          updated_at?: string
        }
        Update: {
          fare_cents?: number
          hold_id?: string | null
          id?: string
          seat_id?: string
          status?: Database["public"]["Enums"]["trip_seat_status"]
          trip_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "trip_seats_hold_id_fkey"
            columns: ["hold_id"]
            isOneToOne: false
            referencedRelation: "seat_holds"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_seats_seat_id_fkey"
            columns: ["seat_id"]
            isOneToOne: false
            referencedRelation: "seats"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_seats_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          operator_id: string | null
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          operator_id?: string | null
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          operator_id?: string | null
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_roles_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      wallet: {
        Row: {
          balance_cents: number
          created_at: string
          currency_code: string
          id: string
          owner_id: string
          owner_type: Database["public"]["Enums"]["wallet_owner_type"]
          updated_at: string
        }
        Insert: {
          balance_cents?: number
          created_at?: string
          currency_code?: string
          id?: string
          owner_id: string
          owner_type: Database["public"]["Enums"]["wallet_owner_type"]
          updated_at?: string
        }
        Update: {
          balance_cents?: number
          created_at?: string
          currency_code?: string
          id?: string
          owner_id?: string
          owner_type?: Database["public"]["Enums"]["wallet_owner_type"]
          updated_at?: string
        }
        Relationships: []
      }
      wallet_transactions: {
        Row: {
          amount_cents: number
          created_at: string
          description: string | null
          id: string
          reference_id: string | null
          reference_type: string | null
          type: Database["public"]["Enums"]["wallet_txn_type"]
          wallet_id: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          description?: string | null
          id?: string
          reference_id?: string | null
          reference_type?: string | null
          type: Database["public"]["Enums"]["wallet_txn_type"]
          wallet_id: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          description?: string | null
          id?: string
          reference_id?: string | null
          reference_type?: string | null
          type?: Database["public"]["Enums"]["wallet_txn_type"]
          wallet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "wallet_transactions_wallet_id_fkey"
            columns: ["wallet_id"]
            isOneToOne: false
            referencedRelation: "wallet"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_cargo_shipment: {
        Args: { p_shipment_id: string; p_vehicle_id: string }
        Returns: Json
      }
      am_i_platform_admin: { Args: never; Returns: boolean }
      cancel_booking: {
        Args: { p_booking_id: string; p_reason?: string }
        Returns: Json
      }
      cancel_shipment: {
        Args: { p_reason?: string; p_shipment_id: string }
        Returns: Json
      }
      confirm_booking_after_payment: {
        Args: {
          p_amount_cents: number
          p_order_reference: string
          p_payment_id: string
        }
        Returns: Json
      }
      confirm_cargo_delivery: {
        Args: {
          p_proof_url: string
          p_recipient_name: string
          p_shipment_id: string
        }
        Returns: Json
      }
      confirm_cargo_pickup: {
        Args: { p_proof_url: string; p_shipment_id: string }
        Returns: Json
      }
      confirm_refund: {
        Args: { p_payment_id: string; p_razorpay_refund_id: string }
        Returns: undefined
      }
      create_booking: {
        Args: {
          p_boarding_point_id: string
          p_contact_email: string
          p_contact_phone: string
          p_dropping_point_id: string
          p_hold_token: string
          p_passengers: Json
        }
        Returns: Json
      }
      create_seat_hold: {
        Args: {
          p_seat_ids: string[]
          p_trip_id: string
          p_ttl_seconds?: number
        }
        Returns: Json
      }
      create_shipment: { Args: { p_shipment: Json }; Returns: Json }
      custom_access_token_hook: { Args: { event: Json }; Returns: Json }
      estimate_cargo_price: {
        Args: {
          p_cargo_type_id: string
          p_route_id: string
          p_vehicle_type_id: string
          p_weight_kg: number
        }
        Returns: Json
      }
      generate_manifest: { Args: { p_trip_id: string }; Returns: Json }
      generate_ticket_qr: {
        Args: { p_booking_item_id: string }
        Returns: string
      }
      get_app_secret: { Args: { p_key: string }; Returns: string }
      get_cargo_quote: {
        Args: {
          p_cargo_type_id: string
          p_destination_city_id: string
          p_source_city_id: string
          p_weight_kg: number
        }
        Returns: Json
      }
      get_trip_seat_map: { Args: { p_trip_id: string }; Returns: Json }
      handle_payment_failure: {
        Args: { p_order_reference: string }
        Returns: undefined
      }
      register_device_token: {
        Args: { p_fcm_token: string; p_platform: string }
        Returns: undefined
      }
      register_operator: {
        Args: {
          p_business_type: Database["public"]["Enums"]["operator_business_type"]
          p_contact_email: string
          p_contact_phone: string
          p_legal_name: string
          p_name: string
        }
        Returns: {
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          rating: number | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "operators"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      reject_cargo_shipment: {
        Args: { p_reason?: string; p_shipment_id: string }
        Returns: Json
      }
      release_seat_hold: { Args: { p_hold_token: string }; Returns: undefined }
      search_cities: {
        Args: { p_limit?: number; p_query?: string }
        Returns: {
          country_id: string
          created_at: string
          id: string
          is_active: boolean
          latitude: number | null
          longitude: number | null
          name: string
          state: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "cities"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      search_trips: {
        Args: {
          p_destination_city_id: string
          p_source_city_id: string
          p_travel_date: string
        }
        Returns: Json
      }
      track_bus_trip: { Args: { p_trip_id: string }; Returns: Json }
      track_cargo_shipment: { Args: { p_shipment_id: string }; Returns: Json }
      update_bus_location: {
        Args: { p_latitude: number; p_longitude: number; p_trip_id: string }
        Returns: Json
      }
      update_cargo_location: {
        Args: { p_latitude: number; p_longitude: number; p_shipment_id: string }
        Returns: Json
      }
      update_cargo_status: {
        Args: {
          p_new_status: Database["public"]["Enums"]["cargo_shipment_status"]
          p_note?: string
          p_shipment_id: string
        }
        Returns: Json
      }
      verify_ticket_qr: { Args: { p_qr_payload: string }; Returns: Json }
    }
    Enums: {
      app_role:
        | "customer"
        | "operator_admin"
        | "operator_staff"
        | "driver"
        | "conductor"
        | "platform_admin"
        | "platform_support"
      booking_status:
        | "draft"
        | "hold_created"
        | "payment_pending"
        | "confirmed"
        | "cancelled"
        | "completed"
        | "expired"
        | "failed"
      bus_service_status: "active" | "paused" | "retired"
      bus_status: "active" | "maintenance" | "inactive"
      bus_trip_status:
        | "scheduled"
        | "boarding"
        | "departed"
        | "arrived"
        | "cancelled"
      cargo_point_type: "address" | "hub"
      cargo_shipment_status:
        | "draft"
        | "confirmed"
        | "picked_up"
        | "in_transit"
        | "arrived_at_hub"
        | "out_for_delivery"
        | "delivered"
        | "cancelled"
        | "failed"
      cargo_speed: "standard" | "express" | "same_day"
      gender_restriction: "none" | "female"
      operator_business_type: "bus" | "cargo" | "both"
      operator_status: "pending" | "approved" | "rejected" | "suspended"
      order_status: "created" | "paid" | "failed" | "cancelled" | "refunded"
      orderable_type: "booking" | "cargo_shipment"
      passenger_gender: "male" | "female" | "other"
      payment_status: "pending" | "captured" | "failed" | "refunded"
      refund_status: "pending" | "processed" | "failed"
      seat_hold_status: "active" | "confirmed" | "released" | "expired"
      seat_type: "seater" | "sleeper"
      trip_seat_status:
        | "available"
        | "held"
        | "booked"
        | "blocked"
        | "cancelled"
        | "boarded"
      wallet_owner_type: "profile" | "operator"
      wallet_txn_type: "credit" | "debit"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: [
        "customer",
        "operator_admin",
        "operator_staff",
        "driver",
        "conductor",
        "platform_admin",
        "platform_support",
      ],
      booking_status: [
        "draft",
        "hold_created",
        "payment_pending",
        "confirmed",
        "cancelled",
        "completed",
        "expired",
        "failed",
      ],
      bus_service_status: ["active", "paused", "retired"],
      bus_status: ["active", "maintenance", "inactive"],
      bus_trip_status: [
        "scheduled",
        "boarding",
        "departed",
        "arrived",
        "cancelled",
      ],
      cargo_point_type: ["address", "hub"],
      cargo_shipment_status: [
        "draft",
        "confirmed",
        "picked_up",
        "in_transit",
        "arrived_at_hub",
        "out_for_delivery",
        "delivered",
        "cancelled",
        "failed",
      ],
      cargo_speed: ["standard", "express", "same_day"],
      gender_restriction: ["none", "female"],
      operator_business_type: ["bus", "cargo", "both"],
      operator_status: ["pending", "approved", "rejected", "suspended"],
      order_status: ["created", "paid", "failed", "cancelled", "refunded"],
      orderable_type: ["booking", "cargo_shipment"],
      passenger_gender: ["male", "female", "other"],
      payment_status: ["pending", "captured", "failed", "refunded"],
      refund_status: ["pending", "processed", "failed"],
      seat_hold_status: ["active", "confirmed", "released", "expired"],
      seat_type: ["seater", "sleeper"],
      trip_seat_status: [
        "available",
        "held",
        "booked",
        "blocked",
        "cancelled",
        "boarded",
      ],
      wallet_owner_type: ["profile", "operator"],
      wallet_txn_type: ["credit", "debit"],
    },
  },
} as const
