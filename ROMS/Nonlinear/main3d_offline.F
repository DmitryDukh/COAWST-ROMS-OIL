#include "cppdefs.h"
#if defined NONLINEAR && defined SOLVE3D && (defined OFFLINE)
      SUBROUTINE main3d_offline (RunInterval)
!
!svn $Id$: main3d_offline.F 830 2017-01-24 21:21:11Z arango $
!=======================================================================
!  Copyright (c) 2002-2016 The ROMS/TOMS Group                         !
!    Licensed under a MIT/X style license                              !
!    See License_ROMS.txt                           Hernan G. Arango   !
!========================================== Alexander F. Shchepetkin ===
!                                                                      !
!  This subroutine is the main driver for nonlinear ROMS/TOMS when     !
!  configurated as a full 3D baroclinic ocean model.  It  advances     !
!  forward the primitive equations for all  nested  grids, if any,     !
!  for the specified time interval (seconds), RunInterval.             !
!  forward the primitive equations for a single time step.             !
!                                                                      !
!=======================================================================
!
      USE mod_param
      USE mod_parallel
# ifdef MODEL_COUPLING
      USE mod_coupler
# endif
      USE mod_iounits
      USE mod_scalars
      USE mod_stepping
!
# ifdef ANA_VMIX
      USE analytical_mod, ONLY : ana_vmix
# endif
# ifdef BIOLOGY
      USE biology_mod, ONLY : biology
# endif
# ifdef BBL_MODEL
      USE bbl_mod, ONLY : bblm
# endif
# ifdef BULK_FLUXES
#  ifdef CCSM_FLUXES
      USE ccsm_flux_mod, ONLY : ccsm_flux
#  else
      USE bulk_flux_mod, ONLY : bulk_flux
#  endif
# endif
# if defined ALBEDO_CLOUD || defined NCEP_FLUXES
      USE cawdir_eval_mod, ONLY : cawdir_eval
# endif
# if defined NCEP_FLUXES
      USE ncep_flux_mod, ONLY : ncep_flux
# endif
# ifdef BVF_MIXING
      USE bvf_mix_mod, ONLY : bvf_mix
# endif
      USE diag_mod, ONLY : diag
# ifdef TLM_CHECK
      USE dotproduct_mod, ONLY : nl_dotproduct
# endif
# ifdef GLS_MIXING
      USE gls_corstep_mod, ONLY : gls_corstep
      USE gls_prestep_mod, ONLY : gls_prestep
# endif
# if defined DIFF_3DCOEF || defined VISC_3DCOEF
      USE hmixing_mod, ONLY : hmixing
# endif
      USE ini_fields_mod, ONLY : ini_fields, ini_zeta
# ifdef LMD_MIXING
      USE lmd_vmix_mod, ONLY : lmd_vmix
# endif
# ifdef MY25_MIXING
      USE my25_corstep_mod, ONLY : my25_corstep
      USE my25_prestep_mod, ONLY : my25_prestep
# endif
# ifdef NESTING
      USE nesting_mod, ONLY : nesting
# endif
# ifdef AIR_OCEAN
      USE ocean_coupler_mod, ONLY : ocn2atm_coupling
# endif
# ifdef WAVES_OCEAN
      USE ocean_coupler_mod, ONLY : ocn2wav_coupling
# endif
      USE omega_mod, ONLY : omega
# ifdef NEARSHORE_MELLOR
      USE radiation_stress_mod, ONLY : radiation_stress
# endif
# ifndef TS_FIXED
      USE rho_eos_mod, ONLY : rho_eos
# endif
      USE rhs3d_mod, ONLY : rhs3d
# ifdef SEDIMENT
      USE sediment_mod, ONLY : sediment
# endif
# if defined AVERAGES && !defined ADJOINT
      USE set_avg_mod, ONLY : set_avg
# endif
# if defined AVERAGES2 && !defined ADJOINT
      USE set_avg2_mod, ONLY : set_avg2
# endif
# if defined ICE_MODEL && defined ICE_THERMO
      USE ice_frazil_mod, ONLY : ice_frazil
# endif
      USE set_depth_mod,        ONLY : set_depth
      USE set_massflux_mod, ONLY : set_massflux, set_massflux_avg
# if defined SSH_TIDES || defined UV_TIDES || defined POT_TIDES
      USE set_tides_mod, ONLY : set_tides
# endif
      USE set_vbc_mod, ONLY : set_vbc
      USE set_zeta_mod, ONLY : set_zeta, set_avg_zeta
      USE step2d_mod, ONLY : step2d
# ifndef TS_FIXED
      USE step3d_t_mod, ONLY : step3d_t
# endif
      USE step3d_uv_mod, ONLY : step3d_uv
# ifdef FLOATS
      USE step_floats_mod, ONLY : step_floats
# endif
# if defined FLOAT_OIL && defined OIL_EULR
! DDMITRY
      USE lagr2euler_mod
      USE metrics_oil_mod
      USE euler2lagr_mod  !
      USE mod_ocean  ! debug
#   ifdef OIL_BIO
      USE bio_oil_mod
#   endif
# if defined OIL_DEBUG
!      USE mod_param
      USE check_tracer_mod
# endif
! END DD
# endif
      USE wvelocity_mod, ONLY : wvelocity
      USE dateclock_mod, ONLY : time_string

! KMT testing
     !USE mod_ocean 

!
      implicit none
!
!  Imported variable declarations.
!
      real(r8), intent(in) :: RunInterval
!
!  Local variable declarations.
!
      integer :: ng, tile
      integer :: my_iif, next_indx1
# if defined FLOATS
      integer :: Lend, Lstr, chunk_size
! DDMITRY
      real(r8) :: Tstart, Tfinish
#  if defined OIL_DEBUG
      integer :: lfl, ii, jj, kk, inn
      real(r8) :: dmm, tmin, tmax, smin, smax
      real(r8) :: tmn1,tmx1,tmn2,tmx2,tmn3,tmx3
#  endif
! ENDD
# endif
      real(r8) :: my_StepTime
      logical :: FIRSTCALL

!
!=======================================================================
!  Time-step nonlinear 3D primitive equations by the specified time.
!=======================================================================
!
      my_StepTime=0.0_r8
      STEP_LOOP : DO WHILE (my_StepTime.le.RunInterval)

        my_StepTime=my_StepTime+MAXVAL(dt)
!
!  Set time indices and time clock.
!
        DO ng=1,Ngrids
          iic(ng)=iic(ng)+1
          nstp(ng)=1+MOD(iic(ng)-ntstart(ng),2)
          nnew(ng)=3-nstp(ng)
          nrhs(ng)=nstp(ng)
!$OMP MASTER
          time(ng)=time(ng)+dt(ng)
          tdays(ng)=time(ng)*sec2day
          CALL time_string (time(ng), time_code(ng))
!$OMP END MASTER
        END DO
!$OMP BARRIER
!
!-----------------------------------------------------------------------
!  Read in required data, if any, from input NetCDF files.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          CALL get_data (ng)
          IF (exit_flag.ne.NoError) RETURN
        END DO
!
!-----------------------------------------------------------------------
!  If applicable, process input data: time interpolate between data
!  snapshots.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL set_data (ng, tile)
          END DO
!$OMP BARRIER
        END DO
        IF (exit_flag.ne.NoError) RETURN
!
!-----------------------------------------------------------------------
!  Initialize all time levels and compute other initial fields.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          IF (iic(ng).eq.ntstart(ng)) THEN

            ! Set this here so that only occurs the first time
            ! set_avg_zeta is called, the first time step
            FIRSTCALL = .TRUE.


!
!  Initialize free-surface and compute initial level thicknesses and
!  depths.
!
            DO tile=first_tile(ng),last_tile(ng),+1
              ! commented by KMT since I am inputting zeta. Revisit this
              ! if want to be able to calculate zeta instead of
              ! inputting.
              !CALL ini_zeta (ng, tile, iNLM)
              CALL set_avg_zeta(ng, tile, FIRSTCALL)  ! to initialize Zt_avg1
              CALL set_depth (ng, tile, iNLM)
            END DO
!$OMP BARRIER
!
!  Initialize other state variables.
!
            DO tile=first_tile(ng),last_tile(ng),+1
              CALL ini_fields (ng, tile, iNLM)
            END DO
!$OMP BARRIER
          END IF
        END DO
!-----------------------------------------------------------------------
!  Compute horizontal mass fluxes (Hz*u/n and Hz*v/m), density related
!  quantities and report global diagnostics.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL set_massflux (ng, tile, iNLM)
# ifndef TS_FIXED
            CALL rho_eos (ng, tile, iNLM)
# endif
            CALL diag (ng, tile)
          END DO
!$OMP BARRIER
        END DO
        IF (exit_flag.ne.NoError) RETURN
# ifdef NESTING
        CALL nesting (5)
# endif

# if defined OFFLINE_TPASSIVE || defined OFFLINE_BIOLOGY || \
     defined BIOLOGY || defined SEDIMENT || defined OIL_EULR
!-----------------------------------------------------------------------
!  Set fields for vertical boundary conditions. Process tidal forcing,
!  if any.
#  if defined ADJUST_STFLUX || defined ADJUST_WSTRESS
!  Interpolate surface forcing increments and adjust surface forcing.
!  Load surface forcing into storage arrays.
#  endif
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
#  if defined NCEP_FLUXES || defined ALBEDO_CLOUD
            CALL cawdir_eval(ng, tile)
#  endif
#  ifdef BULK_FLUXES
#   ifdef CCSM_FLUXES
            CALL ccsm_flux (ng, tile)
#   else
            CALL bulk_flux (ng, tile)
#   endif
#  endif
#  ifdef NCEP_FLUXES
            CALL ncep_flux(ng, tile)
#  endif
#  ifdef BBL_MODEL
            CALL bblm (ng, tile)
#  endif
            CALL set_vbc (ng, tile)
#  if defined SSH_TIDES || defined UV_TIDES || defined POT_TIDES
            CALL set_tides (ng, tile)
#  endif
          END DO
!$OMP BARRIER
        END DO
#  ifdef NESTING
        CALL nesting (9)
#  endif

#  if defined ICE_MODEL
!
!-----------------------------------------------------------------------
!  Run ice model for one step
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          CALL seaice(ng)
        END DO
#  endif
# endif /* if defined OFFLINE_TPASSE ... */
!
!-----------------------------------------------------------------------
!  Compute time-dependent vertical/horizontal mixing coefficients for
!  momentum and tracers. Compute S-coordinate vertical velocity,
!  diagnostically from horizontal mass divergence.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
!! DDMITRY cpp flags
# if defined OFFLINE_TPASSIVE || defined OFFLINE_BIOLOGY || \
     defined BIOLOGY || defined SEDIMENT 
#  if defined ANA_VMIX
            CALL ana_vmix (ng, tile, iNLM)
#  elif defined LMD_MIXING
            CALL lmd_vmix (ng, tile)
#  elif defined BVF_MIXING
            CALL bvf_mix (ng, tile)
#  endif
# endif
# if defined DIFF_3DCOEF || defined VISC_3DCOEF
            CALL hmixing (ng, tile)
# endif
# if !defined OCLIMATOLOGY
            CALL omega (ng, tile, iNLM)
# endif
            CALL wvelocity (ng, tile, nstp(ng))
          END DO
!$OMP BARRIER
        END DO
# ifdef NESTING
        CALL nesting (10)
# endif
!
!-----------------------------------------------------------------------
!  Set free-surface to it time-averaged value.  If applicable,
!  accumulate time-averaged output data which needs a irreversible
!  loop in shared-memory jobs.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            ! KMT commented for all case since will be inputs
            !CALL set_zeta (ng, tile)
# ifdef DIAGNOSTICS
            CALL set_diags (ng, tile)
# endif
# if defined AVERAGES && !defined ADJOINT
            CALL set_avg (ng, tile)
# endif
# if defined AVERAGES2 && !defined ADJOINT
            CALL set_avg2 (ng, tile)
# endif
          END DO
!$OMP BARRIER
        END DO
# ifdef NESTING
        CALL nesting (11)
# endif
!
!-----------------------------------------------------------------------
!  If appropriate, write out fields into output NetCDF files.  Notice
!  that IO data is written in delayed and serial mode.  Exit if last
!  time step.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          CALL output (ng)
          IF ((exit_flag.ne.NoError).or.                                &
     &        ((iic(ng).eq.(ntend(ng)+1)).and.(ng.eq.Ngrids))) RETURN 
        END DO

!
!-----------------------------------------------------------------------
!  Compute right-hand-side terms for 3D equations.
!-----------------------------------------------------------------------
!
! DDMITRY - CPP flags for oil bio sed
# if defined OFFLINE_TPASSIVE || defined OFFLINE_BIOLOGY || \
     defined BIOLOGY || defined SEDIMENT || defined OIL_EULR 
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL rhs3d (ng, tile)
!#   ifdef OIL_DEBUG
! DDMITRY debug
!           IF (Master) CALL check_tracer(ng,'4) main3d_off') 
! END DD
!#   endif

#  if !defined OFFLINE && ( !defined MIXCLIMATOLOGY || !defined AKXCLIMATOLOGY )
#   ifdef MY25_MIXING
            CALL my25_prestep (ng, tile)
#   elif defined GLS_MIXING
            CALL gls_prestep (ng, tile)
#   endif
#  endif
          END DO
!$OMP BARRIER
        END DO
#   ifdef NESTING
        CALL nesting (12)
#   endif

!
!-----------------------------------------------------------------------
!  Recompute depths and thicknesses using the new time filtered
!  free-surface.
!  KMT In this offline case, the fast time steps are not run. Instead,
!  zeta is updated here with the average of this and the subsequent time
!  step values. Then, depths are updated to use this new zeta value
!  (stored in Zt_avg1). 
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL set_avg_zeta (ng, tile, FIRSTCALL)
            CALL set_depth (ng, tile, iNLM)
          END DO
!$OMP BARRIER
        END DO
#  ifdef NESTING
        CALL nesting (14)
#  endif


! KMT this is where step3d_uv would occur in online case. Need to update
! Huon here using the newly calculated depths and the next time step's
! u field?
!-----------------------------------------------------------------------
!  KMT This calculates values for Huon, Hvom, Akt (indices 1 and 2)
!  using updated averaged Zt_avg1 (zeta) value so that offline tracer is
!  calculated correctly. 
!-----------------------------------------------------------------------

        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL set_massflux_avg (ng, tile, iNLM)
          END DO
        END DO

!
!-----------------------------------------------------------------------
!  Time-step vertical mixing turbulent equations and passive tracer
!  source and sink terms, if applicable.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            ! KMT run this even if OCLIMATOLOGY is on because omega
            ! needs to be updated mid-time loop for tracer advection.
            CALL omega (ng, tile, iNLM)
#  if !defined OFFLINE && ( !defined MIXCLIMATOLOGY || !defined AKXCLIMATOLOGY )
#   ifdef MY25_MIXING
            CALL my25_corstep (ng, tile)
#   elif defined GLS_MIXING
            CALL gls_corstep (ng, tile)
#   endif
#  endif /* !defined OFFLINE etc */

! DDMITRY
! -------------------------------------------
! Biology and sediments
! --------------------------------------------
#  ifdef BIOLOGY
            IF (Master) print*,'Calling biology'
            CALL biology (ng, tile)
#  endif
#  ifdef SEDIMENT
            IF (Master) print*,'Calling sediment'
            CALL sediment (ng, tile)
#  endif
          END DO
!$OMP BARRIER
#  if defined FLOAT_OIL && defined OIL_EULR 
! Update OIL information map Euler -> Lagrangian
          IF (Lfloats(ng)) THEN
#   ifdef _OPENMP
            chunk_size=(Nfloats(ng)+numthreads-1)/numthreads
            Lstr=1+MyThread*chunk_size
            Lend=MIN(Nfloats(ng),Lstr+chunk_size-1)
#   else
            Lstr=1
            Lend=Nfloats(ng)
#   endif
! ------------------------------------------------------------
!  Update Oil state in Lagr frame: Euler-> Lagrangian mapping
!  map oil info after biology/sediment weathering processes 
! ------------------------------------------------------------
            DO tile=last_tile(ng),first_tile(ng),-1
#   ifdef OIL_MAP_DEBUG
              IF (Master) THEN
                print*,'=========  Calling euler2lagr ====='
                CALL CPU_TIME(Tstart)
              ENDIF
#   endif
              CALL euler2lagr(ng, tile, Lstr, Lend, nf(ng))
#   ifdef OIL_MAP_DEBUG
              IF (Master) THEN
                CALL CPU_TIME(Tfinish)
                print '("======  euler2lagr done, CPU Time: ",          &
     &                    f8.6," sec")',Tfinish-Tstart
                print*,'   '
              ENDIF
#   endif
            ENDDO  ! tile 
!$OMP BARRIER
          END IF  ! IF Lfloats
#  endif /* FLOAT_OIL OIL_EULR*/
        END DO  ! ng
! END DD
#  ifdef NESTING
        CALL nesting (17)
#  endif
# endif /* defined OFFLINE_TPASSIVE || defined OFFLINE_BIOLOGY*/

# ifndef TS_FIXED
!
!-----------------------------------------------------------------------
!  Time-step tracer equations.
!-----------------------------------------------------------------------
!
! DDMITRY - CPP flags for oil bio and sed
#  if defined OFFLINE_TPASSIVE || defined OFFLINE_BIOLOGY || \
      defined BIOLOGY || defined SEDIMENT
        DO ng=1,Ngrids
          DO tile=first_tile(ng),last_tile(ng),+1
            CALL step3d_t (ng, tile)
#   if defined ICE_MODEL && defined ICE_THERMO
            CALL ice_frazil(ng, tile)
#   endif
          END DO
!$OMP BARRIER
        END DO
!
#   ifdef NESTING
        CALL nesting (18)
#   endif
#  endif
# endif /* ifndef TS_FIXED */

# ifdef OFFLINE_FLOATS
!
!-----------------------------------------------------------------------
!  Compute Lagrangian drifters trajectories: Split all the drifters
!  between all the computational threads, except in distributed-memory
!  and serial configurations. In distributed-memory, the parallel node
!  containing the drifter is selected internally since the state
!  variables do not have a global scope.
!-----------------------------------------------------------------------
!
        DO ng=1,Ngrids
          IF (Lfloats(ng)) THEN
#  ifdef _OPENMP
            chunk_size=(Nfloats(ng)+numthreads-1)/numthreads
            Lstr=1+MyThread*chunk_size
            Lend=MIN(Nfloats(ng),Lstr+chunk_size-1)
#  else
            Lstr=1
            Lend=Nfloats(ng)
#  endif
#  if defined FLOAT_OIL && defined OIL_DEBUG
! DDMITRY
            IF (Master) THEN
              print*,' Calling step_floats'
            ENDIF
#  endif
            CALL step_floats (ng, Lstr, Lend)

#  if defined FLOAT_OIL && defined OIL_EULR 
! DDMITRY 
! Map Lagrangian -> Euler oil floats for biology/sediments modules
! model=iNLM nonlinear model assumed for now
            DO tile=last_tile(ng),first_tile(ng),-1
#   ifdef OIL_MAP_DEBUG
              IF (Master) THEN
                print*,'   ^^^^^^^^^^^^ TILE= ',tile
                print*,'Calling lagr2euler'
                CALL CPU_TIME(Tstart)
              ENDIF
#   endif
              CALL lagr2euler (ng, tile, Lstr, Lend)
#   ifdef OIL_MAP_DEBUG
              IF (Master) THEN
                CALL CPU_TIME(Tfinish)
!
                print '("lagr2euler done, CPU Time: ",                  & 
     &                       f8.6," sec")',Tfinish-Tstart
                print*,' ^^^^^^^^^^^^^  '
              ENDIF
#   endif
              IF ( (MOD(iic(ng),10).eq.0) .and.                         &
     &                 (iic(ng).ne.ntstart(ng)) ) THEN
                CALL metrics_oil (ng, tile, iNLM, Lstr, Lend)
              ENDIF
            ENDDO  ! tile
#  endif
!$OMP BARRIER
!
!  Shift floats time indices.
!
            nfp1(ng)=MOD(nfp1(ng)+1,NFT+1)
            nf(ng)  =MOD(nf(ng)  +1,NFT+1)
            nfm1(ng)=MOD(nfm1(ng)+1,NFT+1)
            nfm2(ng)=MOD(nfm2(ng)+1,NFT+1)
            nfm3(ng)=MOD(nfm3(ng)+1,NFT+1)

          END IF  ! Lfloats
        END DO  ! ng
# endif /* ifdef OFFLINE_FLOATS */

      END DO STEP_LOOP

      RETURN
      END SUBROUTINE main3d_offline
#else
      SUBROUTINE main3d_offline
      RETURN
      END SUBROUTINE main3d_offline
#endif
