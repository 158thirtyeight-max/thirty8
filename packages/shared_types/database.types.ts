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
          arrival_offset_min: number | null
          city_id: string | null
          created_at: string
          departure_offset_min: number | null
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
          arrival_offset_min?: number | null
          city_id?: string | null
          created_at?: string
          departure_offset_min?: number | null
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
          arrival_offset_min?: number | null
          city_id?: string | null
          created_at?: string
          departure_offset_min?: number | null
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
            foreignKeyName: "boarding_points_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
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
      bus_documents: {
        Row: {
          bucket: string
          bus_id: string
          created_at: string
          doc_number: string | null
          doc_type: string
          expiry_date: string | null
          file_name: string | null
          file_path: string
          id: string
          issue_date: string | null
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          bucket?: string
          bus_id: string
          created_at?: string
          doc_number?: string | null
          doc_type: string
          expiry_date?: string | null
          file_name?: string | null
          file_path: string
          id?: string
          issue_date?: string | null
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          bucket?: string
          bus_id?: string
          created_at?: string
          doc_number?: string | null
          doc_type?: string
          expiry_date?: string | null
          file_name?: string | null
          file_path?: string
          id?: string
          issue_date?: string | null
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "bus_documents_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_documents_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_gps_assignments: {
        Row: {
          assigned_at: string
          assigned_by: string | null
          bus_id: string
          device_id: string
          id: string
          unassigned_at: string | null
        }
        Insert: {
          assigned_at?: string
          assigned_by?: string | null
          bus_id: string
          device_id: string
          id?: string
          unassigned_at?: string | null
        }
        Update: {
          assigned_at?: string
          assigned_by?: string | null
          bus_id?: string
          device_id?: string
          id?: string
          unassigned_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bus_gps_assignments_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_gps_assignments_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_gps_assignments_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "gps_devices"
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
          bus_id: string | null
          created_at: string
          destination_city_id: string
          direction: string
          distance_km: number | null
          id: string
          linked_route_id: string | null
          operator_id: string
          revision_journey_id: string | null
          source_city_id: string
        }
        Insert: {
          active?: boolean
          bus_id?: string | null
          created_at?: string
          destination_city_id: string
          direction?: string
          distance_km?: number | null
          id?: string
          linked_route_id?: string | null
          operator_id: string
          revision_journey_id?: string | null
          source_city_id: string
        }
        Update: {
          active?: boolean
          bus_id?: string | null
          created_at?: string
          destination_city_id?: string
          direction?: string
          distance_km?: number | null
          id?: string
          linked_route_id?: string | null
          operator_id?: string
          revision_journey_id?: string | null
          source_city_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bus_routes_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_routes_destination_city_id_fkey"
            columns: ["destination_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_routes_linked_route_id_fkey"
            columns: ["linked_route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
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
            foreignKeyName: "bus_routes_revision_journey_id_fkey"
            columns: ["revision_journey_id"]
            isOneToOne: false
            referencedRelation: "route_revision_journeys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_routes_source_city_id_fkey"
            columns: ["source_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      bus_services: {
        Row: {
          boarding_cutoff_min: number
          booking_cutoff_min: number
          booking_open_days_before: number
          bus_id: string
          created_at: string
          default_arrival_offset_minutes: number
          default_departure_time: string
          direction: string
          est_duration_min: number | null
          id: string
          operating_days: number[]
          operator_id: string
          route_id: string
          schedule_configured: boolean
          service_code: string | null
          service_dest_city_id: string
          service_name: string
          service_source_city_id: string
          status: Database["public"]["Enums"]["bus_service_status"]
          updated_at: string
        }
        Insert: {
          boarding_cutoff_min?: number
          booking_cutoff_min?: number
          booking_open_days_before?: number
          bus_id: string
          created_at?: string
          default_arrival_offset_minutes: number
          default_departure_time: string
          direction?: string
          est_duration_min?: number | null
          id?: string
          operating_days?: number[]
          operator_id: string
          route_id: string
          schedule_configured?: boolean
          service_code?: string | null
          service_dest_city_id: string
          service_name: string
          service_source_city_id: string
          status?: Database["public"]["Enums"]["bus_service_status"]
          updated_at?: string
        }
        Update: {
          boarding_cutoff_min?: number
          booking_cutoff_min?: number
          booking_open_days_before?: number
          bus_id?: string
          created_at?: string
          default_arrival_offset_minutes?: number
          default_departure_time?: string
          direction?: string
          est_duration_min?: number | null
          id?: string
          operating_days?: number[]
          operator_id?: string
          route_id?: string
          schedule_configured?: boolean
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
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bus_services_service_source_city_id_fkey"
            columns: ["service_source_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
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
          location_confidence: number | null
          location_source: string | null
          location_status: string | null
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
          location_confidence?: number | null
          location_source?: string | null
          location_status?: string | null
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
          location_confidence?: number | null
          location_source?: string | null
          location_status?: string | null
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
          {
            foreignKeyName: "bus_trips_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "service_stops"
            referencedColumns: ["service_id"]
          },
        ]
      }
      buses: {
        Row: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        Insert: {
          activated_at?: string | null
          active_route_revision_id?: string | null
          allow_driver_fallback?: boolean
          amenities?: string[]
          approved_at?: string | null
          approved_by?: string | null
          bus_type: string
          chassis_number?: string | null
          created_at?: string
          engine_number?: string | null
          exterior_photo_keys?: string[]
          exterior_photo_path?: string | null
          id?: string
          interior_photo_keys?: string[]
          interior_photo_path?: string | null
          is_legacy?: boolean
          legacy_migration_status?: string | null
          legacy_reviewed_at?: string | null
          legacy_reviewed_by?: string | null
          lifecycle_status?: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer?: string | null
          manufacturing_year?: number | null
          model?: string | null
          name?: string | null
          operator_id: string
          photo_urls?: string[]
          registration_number: string
          registration_year?: number | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: Database["public"]["Enums"]["bus_status"]
          submitted_at?: string | null
          total_seats: number
          updated_at?: string
        }
        Update: {
          activated_at?: string | null
          active_route_revision_id?: string | null
          allow_driver_fallback?: boolean
          amenities?: string[]
          approved_at?: string | null
          approved_by?: string | null
          bus_type?: string
          chassis_number?: string | null
          created_at?: string
          engine_number?: string | null
          exterior_photo_keys?: string[]
          exterior_photo_path?: string | null
          id?: string
          interior_photo_keys?: string[]
          interior_photo_path?: string | null
          is_legacy?: boolean
          legacy_migration_status?: string | null
          legacy_reviewed_at?: string | null
          legacy_reviewed_by?: string | null
          lifecycle_status?: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer?: string | null
          manufacturing_year?: number | null
          model?: string | null
          name?: string | null
          operator_id?: string
          photo_urls?: string[]
          registration_number?: string
          registration_year?: number | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: Database["public"]["Enums"]["bus_status"]
          submitted_at?: string | null
          total_seats?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "buses_active_route_revision_id_fkey"
            columns: ["active_route_revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "buses_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "buses_legacy_reviewed_by_fkey"
            columns: ["legacy_reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "buses_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "buses_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
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
            referencedRelation: "locations"
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
            referencedRelation: "locations"
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
            referencedRelation: "locations"
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
      document_requirements: {
        Row: {
          active: boolean
          condition: Json
          created_at: string
          doc_type: string
          has_expiry: boolean
          id: string
          label: string
          required: boolean
          scope: string
          sort_order: number
          step: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          condition?: Json
          created_at?: string
          doc_type: string
          has_expiry?: boolean
          id?: string
          label: string
          required?: boolean
          scope: string
          sort_order?: number
          step?: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          condition?: Json
          created_at?: string
          doc_type?: string
          has_expiry?: boolean
          id?: string
          label?: string
          required?: boolean
          scope?: string
          sort_order?: number
          step?: string
          updated_at?: string
        }
        Relationships: []
      }
      dropping_points: {
        Row: {
          address: string | null
          arrival_offset_min: number | null
          city_id: string | null
          created_at: string
          departure_offset_min: number | null
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
          arrival_offset_min?: number | null
          city_id?: string | null
          created_at?: string
          departure_offset_min?: number | null
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
          arrival_offset_min?: number | null
          city_id?: string | null
          created_at?: string
          departure_offset_min?: number | null
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
            foreignKeyName: "dropping_points_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dropping_points_route_id_fkey"
            columns: ["route_id"]
            isOneToOne: false
            referencedRelation: "bus_routes"
            referencedColumns: ["id"]
          },
        ]
      }
      fare_charges: {
        Row: {
          active: boolean
          created_at: string
          flat_cents: number | null
          id: string
          kind: string
          name: string
          percent: number | null
          service_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          flat_cents?: number | null
          id?: string
          kind: string
          name: string
          percent?: number | null
          service_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          flat_cents?: number | null
          id?: string
          kind?: string
          name?: string
          percent?: number | null
          service_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fare_charges_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "bus_services"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fare_charges_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "service_stops"
            referencedColumns: ["service_id"]
          },
        ]
      }
      fare_rules: {
        Row: {
          base_fare_cents: number
          berth: string | null
          created_at: string
          effective_from: string
          effective_to: string | null
          from_boarding_point_id: string | null
          id: string
          seat_category: string | null
          seat_type: Database["public"]["Enums"]["seat_type"]
          service_id: string
          to_dropping_point_id: string | null
        }
        Insert: {
          base_fare_cents: number
          berth?: string | null
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          from_boarding_point_id?: string | null
          id?: string
          seat_category?: string | null
          seat_type: Database["public"]["Enums"]["seat_type"]
          service_id: string
          to_dropping_point_id?: string | null
        }
        Update: {
          base_fare_cents?: number
          berth?: string | null
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          from_boarding_point_id?: string | null
          id?: string
          seat_category?: string | null
          seat_type?: Database["public"]["Enums"]["seat_type"]
          service_id?: string
          to_dropping_point_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fare_rules_from_boarding_point_id_fkey"
            columns: ["from_boarding_point_id"]
            isOneToOne: false
            referencedRelation: "boarding_points"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fare_rules_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "bus_services"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fare_rules_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "service_stops"
            referencedColumns: ["service_id"]
          },
          {
            foreignKeyName: "fare_rules_to_dropping_point_id_fkey"
            columns: ["to_dropping_point_id"]
            isOneToOne: false
            referencedRelation: "dropping_points"
            referencedColumns: ["id"]
          },
        ]
      }
      gps_devices: {
        Row: {
          activation_status: string
          connection_status: string
          created_at: string
          created_by: string | null
          device_identifier: string
          id: string
          imei: string | null
          installed_on: string | null
          integration_type: string | null
          last_communication_at: string | null
          last_error: string | null
          name: string | null
          notes: string | null
          provider: string | null
          provider_config_ref: string | null
          serial_no: string | null
          sim_ref: string | null
          updated_at: string
        }
        Insert: {
          activation_status?: string
          connection_status?: string
          created_at?: string
          created_by?: string | null
          device_identifier: string
          id?: string
          imei?: string | null
          installed_on?: string | null
          integration_type?: string | null
          last_communication_at?: string | null
          last_error?: string | null
          name?: string | null
          notes?: string | null
          provider?: string | null
          provider_config_ref?: string | null
          serial_no?: string | null
          sim_ref?: string | null
          updated_at?: string
        }
        Update: {
          activation_status?: string
          connection_status?: string
          created_at?: string
          created_by?: string | null
          device_identifier?: string
          id?: string
          imei?: string | null
          installed_on?: string | null
          integration_type?: string | null
          last_communication_at?: string | null
          last_error?: string | null
          name?: string | null
          notes?: string | null
          provider?: string | null
          provider_config_ref?: string | null
          serial_no?: string | null
          sim_ref?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "gps_devices_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      gps_integration_events: {
        Row: {
          created_at: string
          device_id: string | null
          id: number
          level: string
          message: string
        }
        Insert: {
          created_at?: string
          device_id?: string | null
          id?: number
          level: string
          message: string
        }
        Update: {
          created_at?: string
          device_id?: string | null
          id?: number
          level?: string
          message?: string
        }
        Relationships: [
          {
            foreignKeyName: "gps_integration_events_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "gps_devices"
            referencedColumns: ["id"]
          },
        ]
      }
      locations: {
        Row: {
          country_id: string
          created_at: string
          drop_order: number
          id: string
          is_active: boolean
          is_drop_enabled: boolean
          is_main_route_enabled: boolean
          is_pickup_enabled: boolean
          latitude: number | null
          location_code: string
          longitude: number | null
          main_route_order: number
          name: string
          normalized_name: string
          pickup_order: number
          port_name: string | null
          state: string | null
          updated_at: string
        }
        Insert: {
          country_id: string
          created_at?: string
          drop_order: number
          id?: string
          is_active?: boolean
          is_drop_enabled?: boolean
          is_main_route_enabled?: boolean
          is_pickup_enabled?: boolean
          latitude?: number | null
          location_code: string
          longitude?: number | null
          main_route_order: number
          name: string
          normalized_name: string
          pickup_order: number
          port_name?: string | null
          state?: string | null
          updated_at?: string
        }
        Update: {
          country_id?: string
          created_at?: string
          drop_order?: number
          id?: string
          is_active?: boolean
          is_drop_enabled?: boolean
          is_main_route_enabled?: boolean
          is_pickup_enabled?: boolean
          latitude?: number | null
          location_code?: string
          longitude?: number | null
          main_route_order?: number
          name?: string
          normalized_name?: string
          pickup_order?: number
          port_name?: string | null
          state?: string | null
          updated_at?: string
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
      operator_bank_details: {
        Row: {
          account_holder_name: string | null
          account_number: string | null
          account_type: string | null
          bank_address: string | null
          bank_name: string | null
          branch_name: string | null
          created_at: string
          ifsc: string | null
          micr: string | null
          operator_id: string
          updated_at: string
        }
        Insert: {
          account_holder_name?: string | null
          account_number?: string | null
          account_type?: string | null
          bank_address?: string | null
          bank_name?: string | null
          branch_name?: string | null
          created_at?: string
          ifsc?: string | null
          micr?: string | null
          operator_id: string
          updated_at?: string
        }
        Update: {
          account_holder_name?: string | null
          account_number?: string | null
          account_type?: string | null
          bank_address?: string | null
          bank_name?: string | null
          branch_name?: string | null
          created_at?: string
          ifsc?: string | null
          micr?: string | null
          operator_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "operator_bank_details_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: true
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_commission_config: {
        Row: {
          created_at: string
          created_by: string | null
          effective_from: string
          id: string
          operator_id: string | null
          rate_bps: number
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          operator_id?: string | null
          rate_bps: number
        }
        Update: {
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          operator_id?: string | null
          rate_bps?: number
        }
        Relationships: [
          {
            foreignKeyName: "operator_commission_config_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operator_commission_config_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_documents: {
        Row: {
          created_at: string
          doc_number: string | null
          doc_type: string
          file_name: string | null
          file_path: string
          id: string
          operator_id: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          doc_number?: string | null
          doc_type: string
          file_name?: string | null
          file_path: string
          id?: string
          operator_id: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          doc_number?: string | null
          doc_type?: string
          file_name?: string | null
          file_path?: string
          id?: string
          operator_id?: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "operator_documents_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operator_documents_reviewed_by_fkey"
            columns: ["reviewed_by"]
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
      operator_kyc: {
        Row: {
          created_at: string
          gst_registered: boolean | null
          gstin: string | null
          operator_id: string
          pan_number: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          gst_registered?: boolean | null
          gstin?: string | null
          operator_id: string
          pan_number?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          gst_registered?: boolean | null
          gstin?: string | null
          operator_id?: string
          pan_number?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "operator_kyc_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: true
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_payment_mandates: {
        Row: {
          created_at: string
          file_name: string | null
          file_path: string
          operator_id: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          template_version: string | null
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          file_name?: string | null
          file_path: string
          operator_id: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          template_version?: string | null
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          file_name?: string | null
          file_path?: string
          operator_id?: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          template_version?: string | null
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "operator_payment_mandates_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: true
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operator_payment_mandates_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_profiles: {
        Row: {
          address: string | null
          business_type_detail: string | null
          city: string | null
          contact_address: string | null
          created_at: string
          district: string | null
          logo_path: string | null
          operator_id: string
          owner_name: string | null
          pin_code: string | null
          state: string | null
          updated_at: string
        }
        Insert: {
          address?: string | null
          business_type_detail?: string | null
          city?: string | null
          contact_address?: string | null
          created_at?: string
          district?: string | null
          logo_path?: string | null
          operator_id: string
          owner_name?: string | null
          pin_code?: string | null
          state?: string | null
          updated_at?: string
        }
        Update: {
          address?: string | null
          business_type_detail?: string | null
          city?: string | null
          contact_address?: string | null
          created_at?: string
          district?: string | null
          logo_path?: string | null
          operator_id?: string
          owner_name?: string | null
          pin_code?: string | null
          state?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "operator_profiles_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: true
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_services: {
        Row: {
          admin_approved: boolean
          created_at: string
          disabled_at: string | null
          enabled_at: string | null
          operator_id: string
          service_type: Database["public"]["Enums"]["operator_service_type"]
          state: Database["public"]["Enums"]["operator_service_state"]
          suspension_reason: string | null
          suspension_source: string | null
          updated_at: string
        }
        Insert: {
          admin_approved?: boolean
          created_at?: string
          disabled_at?: string | null
          enabled_at?: string | null
          operator_id: string
          service_type: Database["public"]["Enums"]["operator_service_type"]
          state?: Database["public"]["Enums"]["operator_service_state"]
          suspension_reason?: string | null
          suspension_source?: string | null
          updated_at?: string
        }
        Update: {
          admin_approved?: boolean
          created_at?: string
          disabled_at?: string | null
          enabled_at?: string | null
          operator_id?: string
          service_type?: Database["public"]["Enums"]["operator_service_type"]
          state?: Database["public"]["Enums"]["operator_service_state"]
          suspension_reason?: string | null
          suspension_source?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "operator_services_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operators: {
        Row: {
          application_status: Database["public"]["Enums"]["application_status"]
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          onboarding_step: number
          rating: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          submitted_at: string | null
          updated_at: string
        }
        Insert: {
          application_status?: Database["public"]["Enums"]["application_status"]
          approved_at?: string | null
          approved_by?: string | null
          business_type?: Database["public"]["Enums"]["operator_business_type"]
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          legal_name?: string | null
          name: string
          onboarding_step?: number
          rating?: number | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          settlement_config?: Json
          status?: Database["public"]["Enums"]["operator_status"]
          submitted_at?: string | null
          updated_at?: string
        }
        Update: {
          application_status?: Database["public"]["Enums"]["application_status"]
          approved_at?: string | null
          approved_by?: string | null
          business_type?: Database["public"]["Enums"]["operator_business_type"]
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          legal_name?: string | null
          name?: string
          onboarding_step?: number
          rating?: number | null
          review_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          settlement_config?: Json
          status?: Database["public"]["Enums"]["operator_status"]
          submitted_at?: string | null
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
          {
            foreignKeyName: "operators_reviewed_by_fkey"
            columns: ["reviewed_by"]
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
      passenger_boarding: {
        Row: {
          boarded_at: string | null
          boarded_by: string | null
          booking_item_id: string
          doc_checked: boolean
          exception_reason: string | null
          status: string
          updated_at: string
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          boarded_at?: string | null
          boarded_by?: string | null
          booking_item_id: string
          doc_checked?: boolean
          exception_reason?: string | null
          status?: string
          updated_at?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          boarded_at?: string | null
          boarded_by?: string | null
          booking_item_id?: string
          doc_checked?: boolean
          exception_reason?: string | null
          status?: string
          updated_at?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "passenger_boarding_boarded_by_fkey"
            columns: ["boarded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "passenger_boarding_booking_item_id_fkey"
            columns: ["booking_item_id"]
            isOneToOne: true
            referencedRelation: "booking_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "passenger_boarding_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      passenger_identity: {
        Row: {
          created_at: string
          doc_number_enc: string
          doc_type: string
          last4: string
          passenger_id: string
          updated_at: string
          verification_status: string
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          created_at?: string
          doc_number_enc: string
          doc_type: string
          last4: string
          passenger_id: string
          updated_at?: string
          verification_status?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          created_at?: string
          doc_number_enc?: string
          doc_type?: string
          last4?: string
          passenger_id?: string
          updated_at?: string
          verification_status?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "passenger_identity_passenger_id_fkey"
            columns: ["passenger_id"]
            isOneToOne: true
            referencedRelation: "passengers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "passenger_identity_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      passenger_location_consent: {
        Row: {
          granted_at: string
          id: string
          purpose_version: number
          revoked_at: string | null
          trip_id: string
          user_id: string
        }
        Insert: {
          granted_at?: string
          id?: string
          purpose_version?: number
          revoked_at?: string | null
          trip_id: string
          user_id: string
        }
        Update: {
          granted_at?: string
          id?: string
          purpose_version?: number
          revoked_at?: string | null
          trip_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "passenger_location_consent_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "passenger_location_consent_user_id_fkey"
            columns: ["user_id"]
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
      platform_settings: {
        Row: {
          key: string
          updated_at: string
          updated_by: string | null
          value: Json
        }
        Insert: {
          key: string
          updated_at?: string
          updated_by?: string | null
          value: Json
        }
        Update: {
          key?: string
          updated_at?: string
          updated_by?: string | null
          value?: Json
        }
        Relationships: [
          {
            foreignKeyName: "platform_settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
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
      route_change_flags: {
        Row: {
          booking_item_id: string
          created_at: string
          id: string
          reason: string
          revision_id: string
          status: string
        }
        Insert: {
          booking_item_id: string
          created_at?: string
          id?: string
          reason: string
          revision_id: string
          status?: string
        }
        Update: {
          booking_item_id?: string
          created_at?: string
          id?: string
          reason?: string
          revision_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "route_change_flags_booking_item_id_fkey"
            columns: ["booking_item_id"]
            isOneToOne: false
            referencedRelation: "booking_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_change_flags_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
        ]
      }
      route_revision_events: {
        Row: {
          actor_id: string | null
          created_at: string
          event: string
          id: string
          meta: Json
          reason: string | null
          revision_id: string
        }
        Insert: {
          actor_id?: string | null
          created_at?: string
          event: string
          id?: string
          meta?: Json
          reason?: string | null
          revision_id: string
        }
        Update: {
          actor_id?: string | null
          created_at?: string
          event?: string
          id?: string
          meta?: Json
          reason?: string | null
          revision_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "route_revision_events_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revision_events_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
        ]
      }
      route_revision_journeys: {
        Row: {
          departure_day_offset: number
          departure_time: string | null
          destination_city_id: string | null
          direction: string
          est_duration_min: number | null
          id: string
          operating_days: number[]
          reverse_generated: boolean
          revision_id: string
          source_city_id: string | null
        }
        Insert: {
          departure_day_offset?: number
          departure_time?: string | null
          destination_city_id?: string | null
          direction: string
          est_duration_min?: number | null
          id?: string
          operating_days?: number[]
          reverse_generated?: boolean
          revision_id: string
          source_city_id?: string | null
        }
        Update: {
          departure_day_offset?: number
          departure_time?: string | null
          destination_city_id?: string | null
          direction?: string
          est_duration_min?: number | null
          id?: string
          operating_days?: number[]
          reverse_generated?: boolean
          revision_id?: string
          source_city_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "route_revision_journeys_destination_city_id_fkey"
            columns: ["destination_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revision_journeys_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revision_journeys_source_city_id_fkey"
            columns: ["source_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      route_revision_stops: {
        Row: {
          address: string | null
          arrival_offset_min: number | null
          city_id: string
          departure_offset_min: number | null
          id: string
          is_boarding: boolean
          is_dropping: boolean
          journey_id: string
          latitude: number | null
          longitude: number | null
          sequence_no: number
        }
        Insert: {
          address?: string | null
          arrival_offset_min?: number | null
          city_id: string
          departure_offset_min?: number | null
          id?: string
          is_boarding?: boolean
          is_dropping?: boolean
          journey_id: string
          latitude?: number | null
          longitude?: number | null
          sequence_no: number
        }
        Update: {
          address?: string | null
          arrival_offset_min?: number | null
          city_id?: string
          departure_offset_min?: number | null
          id?: string
          is_boarding?: boolean
          is_dropping?: boolean
          journey_id?: string
          latitude?: number | null
          longitude?: number | null
          sequence_no?: number
        }
        Relationships: [
          {
            foreignKeyName: "route_revision_stops_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revision_stops_journey_id_fkey"
            columns: ["journey_id"]
            isOneToOne: false
            referencedRelation: "route_revision_journeys"
            referencedColumns: ["id"]
          },
        ]
      }
      route_revisions: {
        Row: {
          activated_at: string | null
          admin_authored: boolean
          base_revision_id: string | null
          bus_id: string
          change_reason: string | null
          created_at: string
          created_by: string | null
          id: string
          name: string | null
          operator_id: string
          origin: string
          published_at: string | null
          published_by: string | null
          rejection_reason: string | null
          replaced_revision_id: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          revision_no: number
          source_bus_id: string | null
          source_revision_id: string | null
          status: string
          submitted_at: string | null
          submitted_by: string | null
          trip_type: string
          updated_at: string
        }
        Insert: {
          activated_at?: string | null
          admin_authored?: boolean
          base_revision_id?: string | null
          bus_id: string
          change_reason?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string | null
          operator_id: string
          origin?: string
          published_at?: string | null
          published_by?: string | null
          rejection_reason?: string | null
          replaced_revision_id?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          revision_no: number
          source_bus_id?: string | null
          source_revision_id?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          trip_type?: string
          updated_at?: string
        }
        Update: {
          activated_at?: string | null
          admin_authored?: boolean
          base_revision_id?: string | null
          bus_id?: string
          change_reason?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string | null
          operator_id?: string
          origin?: string
          published_at?: string | null
          published_by?: string | null
          rejection_reason?: string | null
          replaced_revision_id?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          revision_no?: number
          source_bus_id?: string | null
          source_revision_id?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          trip_type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "route_revisions_base_revision_id_fkey"
            columns: ["base_revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_published_by_fkey"
            columns: ["published_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_replaced_revision_id_fkey"
            columns: ["replaced_revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_source_bus_id_fkey"
            columns: ["source_bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_source_revision_id_fkey"
            columns: ["source_revision_id"]
            isOneToOne: false
            referencedRelation: "route_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_revisions_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      route_template_stops: {
        Row: {
          arrival_offset_min: number | null
          city_id: string | null
          departure_offset_min: number | null
          id: string
          is_boarding: boolean
          is_dropping: boolean
          name: string
          sequence_no: number
          template_id: string
        }
        Insert: {
          arrival_offset_min?: number | null
          city_id?: string | null
          departure_offset_min?: number | null
          id?: string
          is_boarding?: boolean
          is_dropping?: boolean
          name: string
          sequence_no: number
          template_id: string
        }
        Update: {
          arrival_offset_min?: number | null
          city_id?: string | null
          departure_offset_min?: number | null
          id?: string
          is_boarding?: boolean
          is_dropping?: boolean
          name?: string
          sequence_no?: number
          template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "route_template_stops_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_template_stops_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "route_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      route_templates: {
        Row: {
          created_at: string
          destination_city_id: string
          distance_km: number | null
          est_duration_min: number | null
          id: string
          is_active: boolean
          name: string
          source_city_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          destination_city_id: string
          distance_km?: number | null
          est_duration_min?: number | null
          id?: string
          is_active?: boolean
          name: string
          source_city_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          destination_city_id?: string
          distance_km?: number | null
          est_duration_min?: number | null
          id?: string
          is_active?: boolean
          name?: string
          source_city_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "route_templates_destination_city_id_fkey"
            columns: ["destination_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "route_templates_source_city_id_fkey"
            columns: ["source_city_id"]
            isOneToOne: false
            referencedRelation: "locations"
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
          boarding_point_id: string | null
          created_at: string
          dropping_point_id: string | null
          expires_at: string
          hold_token: string
          id: string
          quoted_fares: Json | null
          renewal_count: number
          status: Database["public"]["Enums"]["seat_hold_status"]
          trip_id: string
          user_id: string
        }
        Insert: {
          boarding_point_id?: string | null
          created_at?: string
          dropping_point_id?: string | null
          expires_at: string
          hold_token?: string
          id?: string
          quoted_fares?: Json | null
          renewal_count?: number
          status?: Database["public"]["Enums"]["seat_hold_status"]
          trip_id: string
          user_id: string
        }
        Update: {
          boarding_point_id?: string | null
          created_at?: string
          dropping_point_id?: string | null
          expires_at?: string
          hold_token?: string
          id?: string
          quoted_fares?: Json | null
          renewal_count?: number
          status?: Database["public"]["Enums"]["seat_hold_status"]
          trip_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "seat_holds_boarding_point_id_fkey"
            columns: ["boarding_point_id"]
            isOneToOne: false
            referencedRelation: "boarding_points"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "seat_holds_dropping_point_id_fkey"
            columns: ["dropping_point_id"]
            isOneToOne: false
            referencedRelation: "dropping_points"
            referencedColumns: ["id"]
          },
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
          berth: string | null
          bus_layout_id: string
          category: string | null
          col_no: number | null
          created_at: string
          deck: number
          gender_restriction: Database["public"]["Enums"]["gender_restriction"]
          id: string
          kind: string
          role: string | null
          row_no: number | null
          seat_code: string
          seat_type: Database["public"]["Enums"]["seat_type"]
        }
        Insert: {
          berth?: string | null
          bus_layout_id: string
          category?: string | null
          col_no?: number | null
          created_at?: string
          deck?: number
          gender_restriction?: Database["public"]["Enums"]["gender_restriction"]
          id?: string
          kind?: string
          role?: string | null
          row_no?: number | null
          seat_code: string
          seat_type?: Database["public"]["Enums"]["seat_type"]
        }
        Update: {
          berth?: string | null
          bus_layout_id?: string
          category?: string | null
          col_no?: number | null
          created_at?: string
          deck?: number
          gender_restriction?: Database["public"]["Enums"]["gender_restriction"]
          id?: string
          kind?: string
          role?: string | null
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
      settlement_items: {
        Row: {
          booking_item_id: string
          commission_cents: number
          created_at: string
          fare_cents: number
          id: string
          kind: string
          settlement_id: string
        }
        Insert: {
          booking_item_id: string
          commission_cents: number
          created_at?: string
          fare_cents: number
          id?: string
          kind: string
          settlement_id: string
        }
        Update: {
          booking_item_id?: string
          commission_cents?: number
          created_at?: string
          fare_cents?: number
          id?: string
          kind?: string
          settlement_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "settlement_items_booking_item_id_fkey"
            columns: ["booking_item_id"]
            isOneToOne: false
            referencedRelation: "booking_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "settlement_items_settlement_id_fkey"
            columns: ["settlement_id"]
            isOneToOne: false
            referencedRelation: "settlements"
            referencedColumns: ["id"]
          },
        ]
      }
      settlements: {
        Row: {
          commission_cents: number
          completed_at: string | null
          created_at: string
          created_by: string | null
          failure_reason: string | null
          gross_cents: number
          id: string
          initiated_at: string | null
          method: string | null
          net_payable_cents: number
          operator_id: string
          other_deductions_cents: number
          paid_cents: number
          period_end: string
          period_start: string
          reference: string
          refunds_cents: number
          status: string
          txn_reference: string | null
          updated_at: string
        }
        Insert: {
          commission_cents?: number
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          failure_reason?: string | null
          gross_cents?: number
          id?: string
          initiated_at?: string | null
          method?: string | null
          net_payable_cents?: number
          operator_id: string
          other_deductions_cents?: number
          paid_cents?: number
          period_end: string
          period_start: string
          reference: string
          refunds_cents?: number
          status?: string
          txn_reference?: string | null
          updated_at?: string
        }
        Update: {
          commission_cents?: number
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          failure_reason?: string | null
          gross_cents?: number
          id?: string
          initiated_at?: string | null
          method?: string | null
          net_payable_cents?: number
          operator_id?: string
          other_deductions_cents?: number
          paid_cents?: number
          period_end?: string
          period_start?: string
          reference?: string
          refunds_cents?: number
          status?: string
          txn_reference?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "settlements_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "settlements_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_seats: {
        Row: {
          fare_cents: number
          hold_id: string | null
          id: string
          rev: number
          seat_id: string
          status: Database["public"]["Enums"]["trip_seat_status"]
          trip_id: string
          updated_at: string
        }
        Insert: {
          fare_cents?: number
          hold_id?: string | null
          id?: string
          rev?: number
          seat_id: string
          status?: Database["public"]["Enums"]["trip_seat_status"]
          trip_id: string
          updated_at?: string
        }
        Update: {
          fare_cents?: number
          hold_id?: string | null
          id?: string
          rev?: number
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
      vehicle_location_observations: {
        Row: {
          accuracy_m: number | null
          bus_id: string
          device_id: string | null
          heading: number | null
          id: number
          latitude: number
          longitude: number
          received_at: string
          recorded_at: string
          source: string
          speed_kmh: number | null
          trip_id: string | null
          user_id: string | null
        }
        Insert: {
          accuracy_m?: number | null
          bus_id: string
          device_id?: string | null
          heading?: number | null
          id?: number
          latitude: number
          longitude: number
          received_at?: string
          recorded_at: string
          source: string
          speed_kmh?: number | null
          trip_id?: string | null
          user_id?: string | null
        }
        Update: {
          accuracy_m?: number | null
          bus_id?: string
          device_id?: string | null
          heading?: number | null
          id?: number
          latitude?: number
          longitude?: number
          received_at?: string
          recorded_at?: string
          source?: string
          speed_kmh?: number | null
          trip_id?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vehicle_location_observations_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_location_observations_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "gps_devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_location_observations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "bus_trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_location_observations_user_id_fkey"
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
      bus_document_expiry: {
        Row: {
          bus_id: string | null
          days_to_expiry: number | null
          doc_type: string | null
          expiry_date: string | null
          expiry_state: string | null
          id: string | null
          operator_id: string | null
          registration_number: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bus_documents_bus_id_fkey"
            columns: ["bus_id"]
            isOneToOne: false
            referencedRelation: "buses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "buses_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      route_stops: {
        Row: {
          is_drop_allowed: boolean | null
          is_pickup_allowed: boolean | null
          location_id: string | null
          route_id: string | null
          stop_order: number | null
        }
        Relationships: []
      }
      service_stops: {
        Row: {
          drop_enabled: boolean | null
          drop_time: string | null
          location_id: string | null
          pickup_enabled: boolean | null
          pickup_time: string | null
          service_id: string | null
          stop_order: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      accept_cargo_shipment: {
        Args: { p_shipment_id: string; p_vehicle_id: string }
        Returns: Json
      }
      activate_bus: {
        Args: { p_bus_id: string }
        Returns: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "buses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_assign_gps_device: {
        Args: { p_bus_id: string; p_device_id: string }
        Returns: undefined
      }
      admin_assign_route_to_bus: {
        Args: {
          p_bus_id: string
          p_departure_time: string
          p_operating_days: number[]
          p_template_id: string
        }
        Returns: Json
      }
      admin_create_settlement: {
        Args: {
          p_operator_id: string
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      admin_list_gps_devices: { Args: never; Returns: Json }
      admin_list_gps_integration_events: {
        Args: { p_device_id?: string; p_limit?: number }
        Returns: Json
      }
      admin_publish_route_revision: {
        Args: { p_reason: string; p_revision_id: string }
        Returns: Json
      }
      admin_review_bus: {
        Args: { p_action: string; p_bus_id: string; p_reason?: string }
        Returns: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "buses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_review_bus_document: {
        Args: { p_action: string; p_doc_id: string; p_reason?: string }
        Returns: {
          bucket: string
          bus_id: string
          created_at: string
          doc_number: string | null
          doc_type: string
          expiry_date: string | null
          file_name: string | null
          file_path: string
          id: string
          issue_date: string | null
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "bus_documents"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_review_mandate: {
        Args: { p_action: string; p_operator_id: string; p_reason?: string }
        Returns: {
          created_at: string
          file_name: string | null
          file_path: string
          operator_id: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          template_version: string | null
          updated_at: string
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "operator_payment_mandates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_review_operator: {
        Args: { p_action: string; p_operator_id: string; p_reason?: string }
        Returns: {
          application_status: Database["public"]["Enums"]["application_status"]
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          onboarding_step: number
          rating: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          submitted_at: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "operators"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_review_operator_document: {
        Args: { p_action: string; p_doc_id: string; p_reason?: string }
        Returns: {
          created_at: string
          doc_number: string | null
          doc_type: string
          file_name: string | null
          file_path: string
          id: string
          operator_id: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "operator_documents"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_review_route_revision: {
        Args: { p_action: string; p_reason?: string; p_revision_id: string }
        Returns: {
          activated_at: string | null
          admin_authored: boolean
          base_revision_id: string | null
          bus_id: string
          change_reason: string | null
          created_at: string
          created_by: string | null
          id: string
          name: string | null
          operator_id: string
          origin: string
          published_at: string | null
          published_by: string | null
          rejection_reason: string | null
          replaced_revision_id: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          revision_no: number
          source_bus_id: string | null
          source_revision_id: string | null
          status: string
          submitted_at: string | null
          submitted_by: string | null
          trip_type: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "route_revisions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_save_gps_device: {
        Args: { p_data: Json; p_device_id: string }
        Returns: string
      }
      admin_save_route_template: {
        Args: {
          p_destination_city_id: string
          p_distance_km: number
          p_est_duration_min: number
          p_id: string
          p_is_active: boolean
          p_name: string
          p_source_city_id: string
          p_stops: Json
        }
        Returns: string
      }
      admin_set_bus_driver_fallback: {
        Args: { p_bus_id: string; p_enabled: boolean }
        Returns: undefined
      }
      admin_set_commission: {
        Args: {
          p_effective_from?: string
          p_operator_id: string
          p_rate_bps: number
        }
        Returns: string
      }
      admin_set_gps_device_state: {
        Args: { p_device_id: string; p_state: string }
        Returns: undefined
      }
      admin_set_platform_setting: {
        Args: { p_key: string; p_value: Json }
        Returns: undefined
      }
      admin_set_service_state: {
        Args: {
          p_action: string
          p_operator_id: string
          p_reason?: string
          p_service: Database["public"]["Enums"]["operator_service_type"]
        }
        Returns: Json
      }
      admin_unassign_gps_device: {
        Args: { p_device_id: string }
        Returns: undefined
      }
      admin_update_settlement: {
        Args: {
          p_failure_reason?: string
          p_method?: string
          p_paid_cents?: number
          p_settlement_id: string
          p_status: string
          p_txn_reference?: string
        }
        Returns: Json
      }
      am_i_platform_admin: { Args: never; Returns: boolean }
      attach_passenger_documents: {
        Args: { p_booking_reference: string; p_docs: Json }
        Returns: number
      }
      bus_activation_readiness: { Args: { p_bus_id: string }; Returns: Json }
      bus_completeness: { Args: { p_bus_id: string }; Returns: Json }
      bus_verification_state: { Args: { p_bus_id: string }; Returns: string }
      cancel_booking: {
        Args: { p_booking_id: string; p_reason?: string }
        Returns: Json
      }
      cancel_shipment: {
        Args: { p_reason?: string; p_shipment_id: string }
        Returns: Json
      }
      confirm_boarding: { Args: { p_booking_item_id: string }; Returns: Json }
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
      copy_route_to_bus: {
        Args: {
          p_dest_bus_id: string
          p_replace?: boolean
          p_source_bus_id: string
          p_source_revision_id?: string
        }
        Returns: Json
      }
      correct_boarding: {
        Args: { p_booking_item_id: string; p_reason: string }
        Returns: Json
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
      create_bus: {
        Args: {
          p_amenities?: string[]
          p_bus_type: string
          p_chassis_number?: string
          p_engine_number?: string
          p_manufacturer?: string
          p_manufacturing_year?: number
          p_model?: string
          p_name: string
          p_operator_id: string
          p_registration_number: string
          p_registration_year?: number
          p_total_seats: number
        }
        Returns: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "buses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_seat_hold: {
        Args: {
          p_boarding_point_id?: string
          p_dropping_point_id?: string
          p_seat_ids: string[]
          p_trip_id: string
          p_ttl_seconds?: number
        }
        Returns: Json
      }
      create_shipment: { Args: { p_shipment: Json }; Returns: Json }
      custom_access_token_hook: { Args: { event: Json }; Returns: Json }
      deactivate_bus: {
        Args: { p_bus_id: string }
        Returns: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "buses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      estimate_cargo_price: {
        Args: {
          p_cargo_type_id: string
          p_route_id: string
          p_vehicle_type_id: string
          p_weight_kg: number
        }
        Returns: Json
      }
      generate_bus_trips: {
        Args: { p_bus_id: string; p_from: string; p_to: string }
        Returns: number
      }
      generate_manifest: { Args: { p_trip_id: string }; Returns: Json }
      generate_reverse_route: { Args: { p_revision_id: string }; Returns: Json }
      generate_ticket_qr: {
        Args: { p_booking_item_id: string }
        Returns: string
      }
      get_app_secret: { Args: { p_key: string }; Returns: string }
      get_bus_gps_status: { Args: { p_bus_id: string }; Returns: Json }
      get_cargo_quote: {
        Args: {
          p_cargo_type_id: string
          p_destination_city_id: string
          p_source_city_id: string
          p_weight_kg: number
        }
        Returns: Json
      }
      get_journey_points: {
        Args: {
          p_destination_city_id: string
          p_source_city_id: string
          p_travel_date?: string
        }
        Returns: Json
      }
      get_operator_earnings_summary: {
        Args: {
          p_from: string
          p_operator_id: string
          p_service?: string
          p_to: string
        }
        Returns: Json
      }
      get_operator_home_summary: {
        Args: { p_operator_id: string }
        Returns: Json
      }
      get_operator_revenue_trend: {
        Args: {
          p_bucket?: string
          p_from: string
          p_operator_id: string
          p_service?: string
          p_to: string
        }
        Returns: Json
      }
      get_operator_trip_seat_map: { Args: { p_trip_id: string }; Returns: Json }
      get_route_history: { Args: { p_bus_id?: string }; Returns: Json }
      get_route_revision_diff: {
        Args: { p_revision_id: string }
        Returns: Json
      }
      get_service_disable_impact: {
        Args: {
          p_operator_id: string
          p_service: Database["public"]["Enums"]["operator_service_type"]
        }
        Returns: Json
      }
      get_settlement_detail: {
        Args: { p_settlement_id: string }
        Returns: Json
      }
      get_trip_booking_stats: { Args: { p_trip_id: string }; Returns: Json }
      get_trip_booking_trend: { Args: { p_trip_id: string }; Returns: Json }
      get_trip_financials: { Args: { p_trip_id: string }; Returns: Json }
      get_trip_manifest: {
        Args: { p_filter?: string; p_search?: string; p_trip_id: string }
        Returns: Json
      }
      get_trip_points: { Args: { p_trip_id: string }; Returns: Json }
      get_trip_seat_map: {
        Args: {
          p_boarding_point_id?: string
          p_dropping_point_id?: string
          p_trip_id: string
        }
        Returns: Json
      }
      get_trip_tracking: { Args: { p_trip_id: string }; Returns: Json }
      grant_passenger_location_consent: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      handle_payment_failure: {
        Args: { p_order_reference: string }
        Returns: undefined
      }
      ingest_tracker_location: {
        Args: {
          p_accuracy_m?: number
          p_device_identifier: string
          p_heading?: number
          p_latitude: number
          p_longitude: number
          p_provider: string
          p_recorded_at?: string
          p_speed_kmh?: number
        }
        Returns: Json
      }
      list_operator_earnings_by_trip: {
        Args: {
          p_from: string
          p_limit?: number
          p_offset?: number
          p_operator_id: string
          p_to: string
        }
        Returns: Json
      }
      list_operator_settlements: {
        Args: {
          p_limit?: number
          p_offset?: number
          p_operator_id: string
          p_status?: string
        }
        Returns: Json
      }
      list_operator_trips: {
        Args: {
          p_bucket?: string
          p_bus_id?: string
          p_limit?: number
          p_offset?: number
          p_operator_id: string
        }
        Returns: Json
      }
      log_manifest_export: {
        Args: { p_action: string; p_trip_id: string }
        Returns: Json
      }
      mark_boarding_exception: {
        Args: { p_booking_item_id: string; p_reason: string }
        Returns: Json
      }
      operator_block_seats: {
        Args: { p_reason: string; p_seat_ids: string[]; p_trip_id: string }
        Returns: Json
      }
      operator_completeness: { Args: { p_operator_id: string }; Returns: Json }
      operator_disconnect_gps_device: {
        Args: { p_bus_id: string }
        Returns: Json
      }
      operator_register_gps_device: {
        Args: {
          p_bus_id: string
          p_device_identifier: string
          p_imei?: string
          p_name?: string
          p_notes?: string
          p_serial_no?: string
          p_sim_ref?: string
        }
        Returns: Json
      }
      operator_release_seats: {
        Args: { p_reason?: string; p_seat_ids: string[]; p_trip_id: string }
        Returns: Json
      }
      operator_update_gps_device: {
        Args: {
          p_bus_id: string
          p_imei?: string
          p_name?: string
          p_notes?: string
          p_serial_no?: string
          p_sim_ref?: string
        }
        Returns: Json
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
          application_status: Database["public"]["Enums"]["application_status"]
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          onboarding_step: number
          rating: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          submitted_at: string | null
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
      renew_seat_hold: {
        Args: { p_hold_token: string; p_ttl_seconds?: number }
        Returns: Json
      }
      reveal_passenger_document: {
        Args: { p_booking_item_id: string; p_reason: string }
        Returns: Json
      }
      revoke_passenger_location_consent: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      save_bus_fares: {
        Args: { p_bus_id: string; p_charges: Json; p_rules: Json }
        Returns: Json
      }
      save_bus_layout: {
        Args: { p_bus_id: string; p_layout: Json; p_seats: Json }
        Returns: Json
      }
      save_bus_route: {
        Args: {
          p_bus_id: string
          p_departure_time: string
          p_destination_city_id: string
          p_distance_km: number
          p_duration_min: number
          p_operating_days: number[]
          p_source_city_id: string
          p_stops: Json
        }
        Returns: Json
      }
      save_bus_schedule: {
        Args: {
          p_boarding_cutoff_min: number
          p_booking_cutoff_min: number
          p_booking_open_days_before: number
          p_bus_id: string
          p_departure_time: string
          p_operating_days: number[]
        }
        Returns: Json
      }
      save_route_revision: {
        Args: { p_payload: Json; p_revision_id: string }
        Returns: Json
      }
      search_cities: {
        Args: { p_limit?: number; p_query?: string }
        Returns: {
          country_id: string
          created_at: string
          drop_order: number
          id: string
          is_active: boolean
          is_drop_enabled: boolean
          is_main_route_enabled: boolean
          is_pickup_enabled: boolean
          latitude: number | null
          location_code: string
          longitude: number | null
          main_route_order: number
          name: string
          normalized_name: string
          pickup_order: number
          port_name: string | null
          state: string | null
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "locations"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      search_trips: {
        Args: {
          p_destination_city_id: string
          p_drop_location_id?: string
          p_pickup_location_id?: string
          p_source_city_id: string
          p_travel_date: string
        }
        Returns: Json
      }
      set_operator_service: {
        Args: {
          p_confirm?: boolean
          p_enable: boolean
          p_operator_id: string
          p_service: Database["public"]["Enums"]["operator_service_type"]
        }
        Returns: Json
      }
      set_trip_status: {
        Args: { p_status: string; p_trip_id: string }
        Returns: Json
      }
      start_route_revision: {
        Args: { p_base_revision_id?: string; p_bus_id: string }
        Returns: string
      }
      submit_bus: {
        Args: { p_bus_id: string }
        Returns: {
          activated_at: string | null
          active_route_revision_id: string | null
          allow_driver_fallback: boolean
          amenities: string[]
          approved_at: string | null
          approved_by: string | null
          bus_type: string
          chassis_number: string | null
          created_at: string
          engine_number: string | null
          exterior_photo_keys: string[]
          exterior_photo_path: string | null
          id: string
          interior_photo_keys: string[]
          interior_photo_path: string | null
          is_legacy: boolean
          legacy_migration_status: string | null
          legacy_reviewed_at: string | null
          legacy_reviewed_by: string | null
          lifecycle_status: Database["public"]["Enums"]["bus_lifecycle"]
          manufacturer: string | null
          manufacturing_year: number | null
          model: string | null
          name: string | null
          operator_id: string
          photo_urls: string[]
          registration_number: string
          registration_year: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: Database["public"]["Enums"]["bus_status"]
          submitted_at: string | null
          total_seats: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "buses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      submit_operator_application: {
        Args: { p_operator_id: string }
        Returns: {
          application_status: Database["public"]["Enums"]["application_status"]
          approved_at: string | null
          approved_by: string | null
          business_type: Database["public"]["Enums"]["operator_business_type"]
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          legal_name: string | null
          name: string
          onboarding_step: number
          rating: number | null
          review_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          settlement_config: Json
          status: Database["public"]["Enums"]["operator_status"]
          submitted_at: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "operators"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      submit_passenger_location: {
        Args: {
          p_accuracy_m?: number
          p_latitude: number
          p_longitude: number
          p_trip_id: string
        }
        Returns: Json
      }
      submit_route_revision: {
        Args: { p_reason?: string; p_revision_id: string }
        Returns: Json
      }
      sync_bus_capacity_from_layout: {
        Args: { p_bus_id: string }
        Returns: number
      }
      track_bus_trip: { Args: { p_trip_id: string }; Returns: Json }
      track_cargo_shipment: { Args: { p_shipment_id: string }; Returns: Json }
      update_bus_location: {
        Args: {
          p_accuracy_m?: number
          p_latitude: number
          p_longitude: number
          p_trip_id: string
        }
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
      validate_bus_fares: { Args: { p_bus_id: string }; Returns: Json }
      validate_bus_layout: { Args: { p_bus_id: string }; Returns: Json }
      validate_bus_route: { Args: { p_bus_id: string }; Returns: Json }
      validate_bus_schedule: { Args: { p_bus_id: string }; Returns: Json }
      validate_route_revision: {
        Args: { p_revision_id: string }
        Returns: Json
      }
      verify_passenger_boarding: {
        Args: {
          p_booking_item_id: string
          p_doc_checked?: boolean
          p_via?: string
        }
        Returns: Json
      }
      verify_ticket_qr: { Args: { p_qr_payload: string }; Returns: Json }
      withdraw_route_revision: {
        Args: { p_revision_id: string }
        Returns: undefined
      }
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
      application_status:
        | "draft"
        | "submitted"
        | "under_review"
        | "changes_requested"
        | "approved"
        | "rejected"
      booking_status:
        | "draft"
        | "hold_created"
        | "payment_pending"
        | "confirmed"
        | "cancelled"
        | "completed"
        | "expired"
        | "failed"
      bus_lifecycle:
        | "draft"
        | "submitted"
        | "under_review"
        | "changes_requested"
        | "approved"
        | "active"
        | "suspended"
        | "inactive"
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
      operator_service_state:
        | "not_selected"
        | "selected"
        | "setup_required"
        | "pending_approval"
        | "active"
        | "suspended"
        | "disabled"
      operator_service_type: "bus" | "cargo" | "shopping"
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
      application_status: [
        "draft",
        "submitted",
        "under_review",
        "changes_requested",
        "approved",
        "rejected",
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
      bus_lifecycle: [
        "draft",
        "submitted",
        "under_review",
        "changes_requested",
        "approved",
        "active",
        "suspended",
        "inactive",
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
      operator_service_state: [
        "not_selected",
        "selected",
        "setup_required",
        "pending_approval",
        "active",
        "suspended",
        "disabled",
      ],
      operator_service_type: ["bus", "cargo", "shopping"],
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
